require "json"
require "net/http"
require "uri"

module AgentDeployments
  class RpcClient
    def initialize(deployment:)
      @deployment = deployment
    end

    def call(method_name, params = {})
      raise InspectionError, "endpoint URL is required" if deployment.endpoint_url.to_s.blank?
      raise InspectionError, "unsupported transport kind" unless deployment.transport_kind.to_s == "http_jsonrpc"

      uri = URI.parse(deployment.endpoint_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"

      bearer = deployment.deployment_bearer_secret_ref.to_s.strip
      request["Authorization"] = "Bearer #{bearer}" if bearer.present?

      request.body = JSON.generate(
        {
          "jsonrpc" => "2.0",
          "id" => SecureRandom.uuid,
          "method" => method_name.to_s,
          "params" => params,
        },
      )

      response =
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
      unless response.is_a?(Net::HTTPSuccess)
        raise InspectionError, "RPC request failed with #{response.code}: #{response.body}"
      end

      payload = JSON.parse(response.body)
      if payload["error"].is_a?(Hash)
        raise InspectionError, payload["error"]["message"].to_s.presence || "RPC request failed"
      end

      payload.fetch("result")
    rescue URI::InvalidURIError, JSON::ParserError, SocketError, EOFError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise InspectionError, e.message
    end

    private

      attr_reader :deployment
  end
end
