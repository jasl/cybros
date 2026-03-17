require_relative "../test_helper"

class BinTestScriptTest < ActiveSupport::TestCase
  test "bin/test pins the claw verification suite" do
    script = TestPaths.source_root.join("bin/test").read

    assert_includes script, '{ "BUNDLE_GEMFILE" => app_root.join("Gemfile").to_s }'
    assert_includes script, '"bundle",'
    assert_includes script, '"rails",'
    assert_includes script, '"test",'
    assert_includes script, "test/unit/manifest_test.rb"
    assert_includes script, "test/integration/rpc_contract_test.rb"
    assert_includes script, "test/requests/http_boundary_test.rb"
  end
end
