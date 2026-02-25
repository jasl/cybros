require "yaml"

module Conduits
  module DefaultCapabilities
    module_function

    def fs_for(sandbox_profile)
      profile = sandbox_profile.to_s
      defaults = load_defaults
      fs = defaults.dig("fs", profile) || {}

      # Ensure JSON-friendly string keys
      {
        "read" => Array(fs["read"]),
        "write" => Array(fs["write"]),
      }
    end

    def load_defaults
      @load_defaults ||= begin
        path = Rails.root.join("config", "conduits_defaults.yml")
        YAML.safe_load(path.read, permitted_classes: [], permitted_symbols: [], aliases: false) || {}
      end
    end
  end
end
