module Agents
  module BundledSources
    SOURCES = {
      "claw" => Rails.root.join("agents", "claw"),
    }.freeze

    module_function

    def available_keys
      SOURCES.keys.sort
    end

    def path_for(key)
      SOURCES[key.to_s]
    end

    def relative_path_for(key)
      path = path_for(key)
      return nil if path.nil?

      path.relative_path_from(Rails.root).to_s
    rescue ArgumentError
      nil
    end
  end
end
