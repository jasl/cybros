require "test_helper"

module AgentRPC
  class CallbackEndpointTest < ActiveSupport::TestCase
    test "prefers agent rpc callback base url over request and public base urls" do
      with_env(
        "CYBROS_AGENT_RPC_CALLBACK_BASE_URL" => "http://app:3000",
        "CYBROS_BASE_URL" => "http://public.example.test",
      ) do
        begin
          Current.base_url = "http://127.0.0.1:8080"

          assert_equal(
            "http://app:3000/agent_rpc/callbacks/conversation_run/run-123",
            CallbackEndpoint.url(scope_type: "conversation_run", scope_id: "run-123")
          )
        ensure
          Current.base_url = nil
        end
      end
    end

    private

      def with_env(values)
        original = values.keys.index_with { |key| ENV[key] }
        values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
  end
end
