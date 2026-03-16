class HealthController < ApplicationController
  def show
    render json: {
      ok: true,
      status: "healthy",
      identity: boundary_runtime.identity
    }
  end

  private

  def boundary_runtime
    @boundary_runtime ||= Cybros::Agents::Claw::Application.new
  end
end
