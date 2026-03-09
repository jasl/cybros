module AgentRpc
  class CallbackEndpoint
    def self.url(scope_type:, scope_id:)
      new(scope_type: scope_type, scope_id: scope_id).url
    end

    def initialize(scope_type:, scope_id:)
      @scope_type = scope_type.to_s
      @scope_id = scope_id.to_s
    end

    def url
      "#{base_url}#{path}"
    end

    private

      attr_reader :scope_type, :scope_id

      def path
        Rails.application.routes.url_helpers.agent_rpc_callback_path(scope_type: scope_type, scope_id: scope_id)
      end

      def base_url
        base = Current.base_url.presence || ENV["CYBROS_BASE_URL"].to_s.presence || mailer_base_url
        return base.to_s.sub(%r{/+\z}, "") if base.present?

        AgentCore::ValidationError.raise!(
          "Agent RPC callback base URL is not configured.",
          code: "cybros.agent_rpc.callback_base_url_missing",
          details: { scope_type: scope_type, scope_id: scope_id },
        )
      end

      def mailer_base_url
        options = ActionMailer::Base.default_url_options || {}
        host = options[:host].presence || options["host"].presence
        return nil if host.blank?

        protocol = options[:protocol].presence || options["protocol"].presence || "http"
        port = options[:port].presence || options["port"].presence
        "#{protocol}://#{host}#{port.present? ? ":#{port}" : nil}"
      end
  end
end
