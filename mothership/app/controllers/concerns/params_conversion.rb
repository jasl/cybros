module ParamsConversion
  extend ActiveSupport::Concern

  private

  # Convert ActionController::Parameters to a plain hash.
  # Free-form JSON fields (labels, capabilities, limits, etc.) come through
  # as Parameters objects which cannot be merged or stored directly.
  def params_to_h(value, default = {})
    return default if value.nil?
    return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)

    value
  end
end
