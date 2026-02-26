module AgentCore
  module Resources
    module Tools
      module StrictJsonSchema
        module_function

        # Conservative strictification:
        # - For any schema with type: "object", fill missing additionalProperties=false and properties={}
        # - Never changes required semantics
        # - Never raises (best-effort; falls back to original input)
        def normalize(schema)
          normalize_value(schema)
        rescue StandardError
          schema
        end

        def normalize_value(value)
          case value
          when Hash
            normalize_hash(value)
          when Array
            value.map { |v| normalize_value(v) }
          else
            value
          end
        end
        private_class_method :normalize_value

        def normalize_hash(hash)
          out = {}

          hash.each do |k, v|
            out[k] = normalize_value(v)
          end

          return out unless object_schema?(out)

          ap_key = key_for(out, :additionalProperties, "additionalProperties")
          out[ap_key] = false unless out.key?(ap_key)

          props_key = key_for(out, :properties, "properties")
          unless out.key?(props_key)
            out[props_key] = {}
          end

          props = out[props_key]
          out[props_key] = {} unless props.is_a?(Hash)

          out
        rescue StandardError
          hash
        end
        private_class_method :normalize_hash

        def object_schema?(hash)
          t = hash.fetch(:type, hash.fetch("type", nil))
          case t
          when Array
            t.map { |v| v.to_s }.include?("object")
          else
            t.to_s == "object"
          end
        rescue StandardError
          false
        end
        private_class_method :object_schema?

        def key_for(hash, sym, str)
          return sym if hash.key?(sym)
          return str if hash.key?(str)

          hash.keys.any? { |k| k.is_a?(String) } ? str : sym
        rescue StandardError
          sym
        end
        private_class_method :key_for
      end
    end
  end
end
