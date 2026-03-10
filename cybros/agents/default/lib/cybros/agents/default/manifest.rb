module Cybros
  module Agents
    module Default
      class Manifest
        REQUIRED_KEYS = %w[
          agent_program_key
          name
          description
          protocol_version
          agent_sdk_version
          supported_methods
          runtime_surface
          global_config_schema
          conversation_config_schema
          prompts
        ].freeze

        def self.load!(source_root:)
          root = Pathname.new(source_root.to_s)
          data = YAML.safe_load(root.join("agent.yml").read, permitted_classes: [], permitted_symbols: [],
                                                             aliases: false)
          manifest = deep_stringify(data)
          missing = REQUIRED_KEYS.reject { |key| manifest.key?(key) }
          raise KeyError, "agent.yml missing required keys: #{missing.join(", ")}" if missing.any?

          manifest["supported_methods"] = Array(manifest["supported_methods"]).map(&:to_s)
          manifest["runtime_surface"] = deep_stringify(manifest["runtime_surface"])
          manifest["global_config_schema"] = deep_stringify(manifest["global_config_schema"])
          manifest["conversation_config_schema"] = deep_stringify(manifest["conversation_config_schema"])
          manifest["prompts"] = deep_stringify(manifest["prompts"])
          manifest
        end

        def self.deep_stringify(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, child), out| out[key.to_s] = deep_stringify(child) }
          when Array
            value.map { |child| deep_stringify(child) }
          else
            value
          end
        end
      end
    end
  end
end
