module Cybros
  module Permissions
    MODES = %w[conservative default full_access].freeze
    LABELS = {
      "conservative" => "Conservative",
      "default" => "Default",
      "full_access" => "Full access",
    }.freeze
    TOOL_PERMISSION_CLASSES = %w[read mutate delegate boundary].freeze
  end
end
