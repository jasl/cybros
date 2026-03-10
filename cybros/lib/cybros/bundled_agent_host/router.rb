require "json"

module Cybros
  module BundledAgentHost
    class Router
      def initialize(agent_application:, required_bearer: nil)
        @agent_application = agent_application
        @required_bearer = required_bearer.to_s.strip.presence
      end

      def health_payload
        identity = agent_application.identity
        {
          "ok" => true,
          "status" => "healthy",
          "identity" => identity,
          "deployment" => {
            "key" => identity.fetch("agent_deployment_key"),
            "fingerprint" => identity.fetch("deployment_fingerprint"),
          },
        }
      end

      def rpc_payload(method_name:, params:)
        agent_application.call(method_name: method_name, params: params)
      end

      def authorize!(authorization_header)
        return if required_bearer.nil?
        return if authorization_header.to_s == "Bearer #{required_bearer}"

        raise Unauthorized, "invalid bearer"
      end

      private

        attr_reader :agent_application, :required_bearer

        Unauthorized = Class.new(StandardError)
    end
  end
end
