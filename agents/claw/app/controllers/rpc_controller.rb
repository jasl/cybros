class RpcController < ApplicationController
  include JsonRpcErrorRenderer

  rescue_from StandardError, with: :render_internal_error
  rescue_from KeyError, with: :render_unsupported_method
  rescue_from JSON::ParserError, with: :render_parse_error

  def create
    ensure_authorized!

    payload = JSON.parse(request.raw_post.to_s)
    result = boundary_runtime.call(method_name: payload.fetch("method"), params: payload.fetch("params", {}))

    render json: {
      jsonrpc: "2.0",
      id: payload.fetch("id"),
      result: result
    }
  end

  private

  def boundary_runtime
    @boundary_runtime ||= Cybros::Agents::Claw::Application.new
  end

  def ensure_authorized!
    return if request.headers["Authorization"].to_s == "Bearer #{boundary_runtime.required_bearer}"

    raise "invalid bearer"
  end

  def render_unsupported_method(error)
    render_jsonrpc_error(code: -32_601, message: error.message, status: :not_found)
  end

  def render_parse_error(error)
    render_jsonrpc_error(code: -32_700, message: error.message, status: :bad_request)
  end

  def render_internal_error(error)
    render_jsonrpc_error(code: -32_000, message: error.message, status: :internal_server_error)
  end
end
