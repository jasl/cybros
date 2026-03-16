require_relative "../test_helper"

class BinTestScriptTest < ActiveSupport::TestCase
  test "bin/test pins the claw verification suite" do
    script = TestPaths.source_root.join("bin/test").read

    assert_includes script, "test/unit/manifest_test.rb"
    assert_includes script, "test/integration/rpc_contract_test.rb"
    assert_includes script, "test/requests/http_boundary_test.rb"
  end
end
