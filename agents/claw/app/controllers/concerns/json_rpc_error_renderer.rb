module JsonRpcErrorRenderer
  private

  def render_jsonrpc_error(code:, message:, status:)
    render json: {
      jsonrpc: "2.0",
      id: nil,
      error: {
        code: code,
        message: message
      }
    }, status: status
  end
end
