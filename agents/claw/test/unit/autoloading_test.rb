require_relative "../test_helper"

class AutoloadingTest < ActiveSupport::TestCase
  test "rpc dispatcher autoloads with Zeitwerk naming" do
    assert_equal Cybros::Agents::Claw::RPCDispatcher, Cybros::Agents::Claw::RPCDispatcher
  end
end
