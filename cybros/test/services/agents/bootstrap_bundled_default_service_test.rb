require "test_helper"

class Agents::BootstrapBundledDefaultServiceTest < ActiveSupport::TestCase
  test "bootstrap delegates to ensure_agent" do
    service = Agents::BootstrapBundledDefaultService.new
    service.define_singleton_method(:ensure_agent!) { :bootstrapped_agent }

    assert_equal :bootstrapped_agent, service.bootstrap!
  end
end
