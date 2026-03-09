module AgentRpc
  class CallbacksController < ActionController::API
    before_action :set_current_account

    def create
      payload = JSON.parse(request.raw_post.to_s)
      result =
        AgentRpc::CallbackDispatcher.call!(
          bearer: bearer_token,
          method_name: payload.fetch("method"),
          scope_type: params.fetch(:scope_type),
          scope_id: params.fetch(:scope_id),
          payload: payload.fetch("params", {}),
        )

      render json: { "jsonrpc" => "2.0", "id" => payload["id"], "result" => result }
    rescue JSON::ParserError => e
      render json: { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32700, "message" => e.message } }, status: :bad_request
    rescue KeyError => e
      render json: { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32602, "message" => e.message } }, status: :unprocessable_entity
    rescue AgentCore::ValidationError => e
      render json: {
        "jsonrpc" => "2.0",
        "id" => payload&.[]("id"),
        "error" => {
          "code" => e.code,
          "message" => e.message,
          "details" => e.details,
        },
      }, status: :unprocessable_entity
    end

    private

      def bearer_token
        request.authorization.to_s.remove(/\ABearer\s+/)
      end

      def set_current_account
        Current.account = Account.instance
      end
  end
end
