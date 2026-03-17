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
            out[k.to_s] = normalize_value(v)
          end

          return out unless object_schema?(out)

          out["additionalProperties"] = false unless out.key?("additionalProperties")

          out["properties"] = {} unless out.key?("properties")

          props = out["properties"]
          out["properties"] = {} unless props.is_a?(Hash)

          out
        rescue StandardError
          hash
        end
        private_class_method :normalize_hash

        def object_schema?(hash)
          t = hash.fetch("type", nil)
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
      end
    end
  end
end
