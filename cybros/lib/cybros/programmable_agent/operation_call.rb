require "json"
require "securerandom"

module Cybros
  module ProgrammableAgent
    OperationCall = Data.define(
      :tool_call_id,
      :logical_tool_name,
      :arguments,
      :reason,
      :origin,
      :approval_hint,
      :idempotency_key,
    ) do
      TOOL_CALL_ID_PREFIX = "opcall_"

      class << self
        def tool(logical_tool_name:, arguments:, reason:, origin: nil, tool_call_id: nil, approval_hint: nil, idempotency_key: nil)
          new(
            tool_call_id: normalize_tool_call_id(tool_call_id),
            logical_tool_name: normalize_required_string!(logical_tool_name, field_name: :logical_tool_name),
            arguments: normalize_hash(arguments, default: {}),
            reason: normalize_required_string!(reason, field_name: :reason),
            origin: normalize_optional_string(origin),
            approval_hint: normalize_optional_hash(approval_hint),
            idempotency_key: normalize_optional_string(idempotency_key),
          )
        end

        def subagent_spawn(arguments:, reason:, origin: nil, tool_call_id: nil, approval_hint: nil, idempotency_key: nil)
          tool(
            logical_tool_name: "subagent_spawn",
            arguments: arguments,
            reason: reason,
            origin: origin,
            tool_call_id: tool_call_id,
            approval_hint: approval_hint,
            idempotency_key: idempotency_key,
          )
        end

        private

          def normalize_tool_call_id(value)
            normalize_optional_string(value) || "#{TOOL_CALL_ID_PREFIX}#{SecureRandom.hex(12)}"
          end

          def normalize_required_string!(value, field_name:)
            normalized = normalize_optional_string(value)
            raise ArgumentError, "#{field_name} is required" if normalized.blank?

            normalized
          end

          def normalize_optional_string(value)
            value.to_s.strip.presence
          end

          def normalize_hash(value, default:)
            normalized = value.respond_to?(:to_h) ? value.to_h : value
            normalized = default if normalized.nil?
            JSON.parse(JSON.generate(normalized.deep_stringify_keys))
          end

          def normalize_optional_hash(value)
            return nil if value.nil?

            normalize_hash(value, default: {})
          end
      end

      def with_origin(default_origin)
        return self if origin.present? || default_origin.to_s.strip.empty?

        self.class.new(
          tool_call_id: tool_call_id,
          logical_tool_name: logical_tool_name,
          arguments: arguments,
          reason: reason,
          origin: default_origin.to_s.strip,
          approval_hint: approval_hint,
          idempotency_key: idempotency_key,
        )
      end

      def to_queue_payload(sequence_id: nil, step_index: nil, step_count: nil, default_origin: nil)
        resolved = with_origin(default_origin)

        {
          "tool_call_id" => resolved.tool_call_id,
          "logical_tool_name" => resolved.logical_tool_name,
          "arguments" => resolved.arguments,
          "reason" => resolved.reason,
          "origin" => resolved.origin,
          "approval_hint" => resolved.approval_hint,
          "idempotency_key" => resolved.idempotency_key,
          "sequence_id" => sequence_id,
          "step_index" => step_index,
          "step_count" => step_count,
        }
      end
    end
  end
end
