require "test_helper"

class Conduits::FsPolicyV1Test < ActiveSupport::TestCase
  # normalize_path

  test "normalize_path strips trailing slash" do
    assert_equal "/workspace", Conduits::FsPolicyV1.normalize_path("/workspace/")
  end

  test "normalize_path adds leading slash" do
    assert_equal "/workspace", Conduits::FsPolicyV1.normalize_path("workspace")
  end

  test "normalize_path collapses double slashes" do
    assert_equal "/workspace/src", Conduits::FsPolicyV1.normalize_path("/workspace//src")
  end

  test "normalize_path returns / for root" do
    assert_equal "/", Conduits::FsPolicyV1.normalize_path("/")
  end

  test "normalize_path handles workspace:** glob by stripping suffix and adding /" do
    assert_equal "/workspace", Conduits::FsPolicyV1.normalize_path("workspace:**")
  end

  # SECURITY: path traversal resolution

  test "normalize_path resolves path traversal" do
    assert_equal "/etc/passwd", Conduits::FsPolicyV1.normalize_path("/workspace/../etc/passwd")
  end

  test "normalize_path resolves double traversal" do
    assert_equal "/secret", Conduits::FsPolicyV1.normalize_path("/workspace/src/../../secret")
  end

  test "normalize_path resolves dot segments" do
    assert_equal "/workspace/src", Conduits::FsPolicyV1.normalize_path("/workspace/./src")
  end

  test "normalize_path traversal past root clamps to root" do
    assert_equal "/", Conduits::FsPolicyV1.normalize_path("/../../../")
  end

  test "SECURITY: path_covered? rejects traversal attack" do
    refute Conduits::FsPolicyV1.path_covered?("/workspace/../etc/passwd", ["/workspace"])
  end

  test "SECURITY: path_covered? rejects encoded traversal" do
    refute Conduits::FsPolicyV1.path_covered?("/workspace/../../etc/shadow", ["/workspace"])
  end

  # path_covered?

  test "path_covered? exact match" do
    assert Conduits::FsPolicyV1.path_covered?("/workspace", ["/workspace"])
  end

  test "path_covered? prefix match" do
    assert Conduits::FsPolicyV1.path_covered?("/workspace/src/main.rs", ["/workspace"])
  end

  test "path_covered? rejects non-prefix" do
    refute Conduits::FsPolicyV1.path_covered?("/etc/passwd", ["/workspace"])
  end

  test "path_covered? multiple prefixes — matches any" do
    assert Conduits::FsPolicyV1.path_covered?("/tmp/file", ["/workspace", "/tmp"])
  end

  test "path_covered? empty allowed list rejects all" do
    refute Conduits::FsPolicyV1.path_covered?("/workspace/file", [])
  end

  test "path_covered? root prefix covers everything" do
    assert Conduits::FsPolicyV1.path_covered?("/any/path", ["/"])
  end

  test "path_covered? workspace:** glob treated as prefix" do
    assert Conduits::FsPolicyV1.path_covered?("/workspace/file", ["workspace:**"])
  end

  # intersect

  test "intersect overlapping read/write sets keeps common coverage" do
    fs_a = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    fs_b = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    result = Conduits::FsPolicyV1.intersect(fs_a, fs_b)
    assert_includes result["read"], "workspace:**"
    assert_includes result["write"], "workspace:**"
  end

  test "intersect disjoint sets produces empty arrays" do
    fs_a = { "read" => ["/workspace"], "write" => ["/workspace"] }
    fs_b = { "read" => ["/home"], "write" => ["/home"] }
    result = Conduits::FsPolicyV1.intersect(fs_a, fs_b)
    assert_empty result["read"]
    assert_empty result["write"]
  end

  test "intersect with one empty set produces empty" do
    fs_a = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    fs_b = { "read" => [], "write" => [] }
    result = Conduits::FsPolicyV1.intersect(fs_a, fs_b)
    assert_empty result["read"]
    assert_empty result["write"]
  end

  test "intersect with sub-paths keeps more specific" do
    fs_a = { "read" => ["/workspace"], "write" => ["/workspace"] }
    fs_b = { "read" => ["/workspace/src"], "write" => ["/workspace/src"] }
    result = Conduits::FsPolicyV1.intersect(fs_a, fs_b)
    # /workspace/src is covered by /workspace, so keep /workspace/src (narrower)
    assert_includes result["read"], "/workspace/src"
    assert_includes result["write"], "/workspace/src"
  end

  test "intersect nil inputs treated as empty" do
    result = Conduits::FsPolicyV1.intersect(nil, { "read" => ["/workspace"], "write" => [] })
    assert_empty result["read"]
    assert_empty result["write"]
  end

  # evaluate

  test "evaluate allows request within policy ceiling" do
    policy_fs = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    requested_fs = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    result = Conduits::FsPolicyV1.evaluate(requested_fs, policy_fs)
    assert result[:allowed]
    assert_empty result[:violations]
  end

  test "evaluate detects request outside policy ceiling" do
    policy_fs = { "read" => ["workspace:**"], "write" => [] }
    requested_fs = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    result = Conduits::FsPolicyV1.evaluate(requested_fs, policy_fs)
    refute result[:allowed]
    assert_not_empty result[:violations]
  end

  test "evaluate with empty policy allows nothing" do
    policy_fs = { "read" => [], "write" => [] }
    requested_fs = { "read" => ["workspace:**"], "write" => [] }
    result = Conduits::FsPolicyV1.evaluate(requested_fs, policy_fs)
    refute result[:allowed]
  end

  test "evaluate with empty request is always allowed" do
    policy_fs = { "read" => ["workspace:**"], "write" => ["workspace:**"] }
    requested_fs = { "read" => [], "write" => [] }
    result = Conduits::FsPolicyV1.evaluate(requested_fs, policy_fs)
    assert result[:allowed]
  end
end
