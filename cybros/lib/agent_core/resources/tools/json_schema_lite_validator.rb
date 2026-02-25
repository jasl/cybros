# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      module JsonSchemaLiteValidator
        module_function

        DEFAULT_MAX_SUMMARY_BYTES = 400
        DEFAULT_MAX_ARRAY_ITEMS = 50

        # Best-effort JSON Schema validator for tool arguments.
        #
        # Intentionally conservative to avoid false positives:
        # - Only validates object schemas with required/properties present.
        # - Unknown-key validation only when additionalProperties == false AND properties present.
        # - Type checks only for keys present in properties.
        # - Recurses up to max_depth and never raises.
        #
        # @return [Array<Hash>] error hashes with String keys
        def validate(arguments:, schema:, max_depth: 2)
          args = arguments.is_a?(Hash) ? arguments : {}
          sch = schema.is_a?(Hash) ? schema : {}
          depth = Integer(max_depth)
          depth = 0 if depth.negative?

          errors = []
          validate_object!(errors, args, sch, path: [], depth_left: depth)
          errors
        rescue StandardError
          []
        end

        def summarize(errors, max_bytes: DEFAULT_MAX_SUMMARY_BYTES)
          list = Array(errors).select { |e| e.is_a?(Hash) }
          return "" if list.empty?

          parts =
            list.first(20).map do |e|
              code = e.fetch("code", "").to_s
              path = Array(e.fetch("path", [])).map(&:to_s)
              expected = e.fetch("expected", nil)
              actual = e.fetch("actual", nil)

              seg = +"#{code}"
              seg << " path=#{format_path(path)}" unless path.empty?
              seg << " expected=#{expected}" if expected
              seg << " actual=#{actual}" if actual
              seg
            end

          text = parts.join("; ")
          AgentCore::Utils.truncate_utf8_bytes(text, max_bytes: Integer(max_bytes))
        rescue StandardError
          ""
        end

        def format_path(path)
          return "" if path.nil?
          a = Array(path).map(&:to_s)
          a.join(".")
        rescue StandardError
          ""
        end
        private_class_method :format_path

        def validate_object!(errors, value, schema, path:, depth_left:)
          return unless value.is_a?(Hash)
          return unless object_schema?(schema)

          required = fetch_required(schema)
          props = fetch_properties(schema)

          return if (required.nil? || required.empty?) && (props.nil? || props.empty?)

          required.each do |key|
            next if value.key?(key)

            errors << {
              "code" => "missing_required",
              "path" => path + [key],
              "expected" => "present",
            }
          end

          if additional_properties_false?(schema) && props.any?
            value.each_key do |k|
              next if props.key?(k)

              errors << {
                "code" => "unknown_key",
                "path" => path + [k.to_s],
                "expected" => "in_properties",
              }
            end
          end

          props.each do |k, prop_schema|
            next unless value.key?(k)

            validate_value!(errors, value.fetch(k), prop_schema, path: path + [k], depth_left: depth_left)
          end
        rescue StandardError
          nil
        end
        private_class_method :validate_object!

        def validate_array!(errors, value, schema, path:, depth_left:)
          return unless value.is_a?(Array)
          return unless schema_type_includes?(schema, "array")
          return if depth_left < 0

          items = fetch_items(schema)
          return unless items.is_a?(Hash)

          value.first(DEFAULT_MAX_ARRAY_ITEMS).each_with_index do |v, idx|
            validate_value!(errors, v, items, path: path + [idx], depth_left: depth_left)
          end
        rescue StandardError
          nil
        end
        private_class_method :validate_array!

        def validate_value!(errors, value, schema, path:, depth_left:)
          return if depth_left < 0

          sch = schema.is_a?(Hash) ? schema : {}
          expected_types = fetch_types(sch)

          if expected_types.any?
            actual = json_type(value)
            unless type_matches_any?(expected_types, actual)
              errors << {
                "code" => "type_mismatch",
                "path" => path,
                "expected" => expected_types.join("|"),
                "actual" => actual,
              }
              return
            end
          end

          if depth_left <= 0
            return
          end

          if object_schema?(sch)
            validate_object!(errors, value, sch, path: path, depth_left: depth_left - 1)
          elsif schema_type_includes?(sch, "array")
            validate_array!(errors, value, sch, path: path, depth_left: depth_left - 1)
          end
        rescue StandardError
          nil
        end
        private_class_method :validate_value!

        def fetch_required(schema)
          req = schema.fetch("required", schema.fetch(:required, nil))
          Array(req).map { |v| v.to_s }.reject(&:empty?)
        rescue StandardError
          []
        end
        private_class_method :fetch_required

        def fetch_properties(schema)
          props = schema.fetch("properties", schema.fetch(:properties, nil))
          return {} unless props.is_a?(Hash)

          props.each_with_object({}) do |(k, v), out|
            key = k.to_s
            next if key.empty?

            out[key] = v.is_a?(Hash) ? v : {}
          end
        rescue StandardError
          {}
        end
        private_class_method :fetch_properties

        def fetch_items(schema)
          schema.fetch("items", schema.fetch(:items, nil))
        rescue StandardError
          nil
        end
        private_class_method :fetch_items

        def fetch_types(schema)
          t = schema.fetch("type", schema.fetch(:type, nil))
          case t
          when Array
            t.map { |v| v.to_s }.reject(&:empty?)
          when nil
            []
          else
            s = t.to_s
            s.empty? ? [] : [s]
          end
        rescue StandardError
          []
        end
        private_class_method :fetch_types

        def object_schema?(schema)
          schema_type_includes?(schema, "object")
        rescue StandardError
          false
        end
        private_class_method :object_schema?

        def schema_type_includes?(schema, expected)
          return false unless schema.is_a?(Hash)

          types = fetch_types(schema)
          types.map(&:to_s).include?(expected.to_s)
        rescue StandardError
          false
        end
        private_class_method :schema_type_includes?

        def additional_properties_false?(schema)
          ap = schema.fetch("additionalProperties", schema.fetch(:additionalProperties, schema.fetch(:additional_properties, schema.fetch("additional_properties", nil))))
          ap == false
        rescue StandardError
          false
        end
        private_class_method :additional_properties_false?

        def type_matches_any?(expected_types, actual_type)
          expected_types.any? do |t|
            et = t.to_s
            next true if et == actual_type
            next true if et == "number" && actual_type == "integer"

            false
          end
        rescue StandardError
          true
        end
        private_class_method :type_matches_any?

        def json_type(value)
          case value
          when NilClass then "null"
          when TrueClass, FalseClass then "boolean"
          when String then "string"
          when Integer then "integer"
          when Numeric then "number"
          when Hash then "object"
          when Array then "array"
          else "unknown"
          end
        rescue StandardError
          "unknown"
        end
        private_class_method :json_type
      end
    end
  end
end
