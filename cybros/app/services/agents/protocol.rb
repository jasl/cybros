require "uri"

module Agents
  module Protocol
    SUPPORTED_PROTOCOL_VERSION = "agent_rpc.v1".freeze
    ATTACHMENT_IMPORT_METHOD = "attachments.import".freeze
    REQUIRED_METHODS = %w[
      initialize
      agent.describe
      agent.health
      agent.schemas.get
      capabilities.handshake
      capabilities.refresh
      on_conversation_created
      on_lane_first_user_message
      before_agent_step
      on_context_pressure
      before_subagent_spawn
      before_finalize_output
      after_task_notice
      after_subagent_result
    ].freeze
    DEFAULT_SUPPORTED_METHODS =
      REQUIRED_METHODS.dup.tap do |methods|
        methods.insert(methods.index("capabilities.refresh") + 1, ATTACHMENT_IMPORT_METHOD)
      end.freeze
    ATTACHMENT_DESCRIPTOR_REQUIRED_KEYS = %w[id filename content_type byte_size digest signed_download_url].freeze
    ATTACHMENT_DESCRIPTOR_RAW_BYTES_KEYS = %w[bytes bytes_base64 raw_bytes content].freeze

    module_function

    def normalize_attachment_import_params!(params)
      normalized = stringify_hash(params)

      {
        "attachments" => normalize_attachment_descriptors!(normalized["attachments"]),
      }
    end

    def normalize_attachment_descriptors!(value)
      attachments = Array(value)
      if attachments.empty?
        AgentCore::ValidationError.raise!(
          "attachments.import requires at least one attachment descriptor",
          code: "cybros.agents.protocol.attachment_descriptors_are_required",
        )
      end

      attachments.map.with_index do |descriptor, index|
        normalize_attachment_descriptor!(descriptor, index: index)
      end
    end

    def attachment_import_supported?(supported_methods)
      Array(supported_methods).map(&:to_s).include?(ATTACHMENT_IMPORT_METHOD)
    end

    private_class_method def normalize_attachment_descriptor!(descriptor, index:)
      normalized = stringify_hash(descriptor)
      raw_bytes_key = ATTACHMENT_DESCRIPTOR_RAW_BYTES_KEYS.find { |key| normalized.key?(key) }
      if raw_bytes_key
        AgentCore::ValidationError.raise!(
          "attachments.import only accepts descriptors with signed download URLs",
          code: "cybros.agents.protocol.attachment_descriptor_raw_bytes_are_not_allowed",
          details: { index: index, key: raw_bytes_key },
        )
      end

      missing = ATTACHMENT_DESCRIPTOR_REQUIRED_KEYS.reject { |key| normalized[key].to_s.strip != "" }
      if missing.any?
        AgentCore::ValidationError.raise!(
          "attachment descriptor is missing required fields",
          code: "cybros.agents.protocol.attachment_descriptor_missing_fields",
          details: { index: index, missing: missing },
        )
      end

      signed_download_url = normalized["signed_download_url"].to_s.strip
      uri = URI.parse(signed_download_url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        AgentCore::ValidationError.raise!(
          "attachment descriptor signed download URL must be http(s)",
          code: "cybros.agents.protocol.attachment_descriptor_signed_download_url_must_be_http",
          details: { index: index, signed_download_url: signed_download_url },
        )
      end

      {
        "id" => normalized["id"].to_s,
        "filename" => normalized["filename"].to_s,
        "content_type" => normalized["content_type"].to_s,
        "byte_size" => Integer(normalized["byte_size"]),
        "digest" => normalized["digest"].to_s,
        "signed_download_url" => signed_download_url,
        "workspace" => normalize_attachment_workspace(normalized["workspace"]),
        "conversation" => stringify_hash(normalized["conversation"]),
        "metadata" => stringify_hash(normalized["metadata"]),
      }.reject { |_key, value| value == {} }
    rescue ArgumentError, TypeError
      AgentCore::ValidationError.raise!(
        "attachment descriptor byte_size must be an integer",
        code: "cybros.agents.protocol.attachment_descriptor_byte_size_must_be_integer",
        details: { index: index, byte_size: normalized["byte_size"] },
      )
    rescue URI::InvalidURIError
      AgentCore::ValidationError.raise!(
        "attachment descriptor signed download URL must be valid",
        code: "cybros.agents.protocol.attachment_descriptor_signed_download_url_must_be_valid",
        details: { index: index, signed_download_url: normalized["signed_download_url"] },
      )
    end

    private_class_method def stringify_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, child), out|
        out[key.to_s] =
          case child
          when Hash
            stringify_hash(child)
          when Array
            child.map { |entry| entry.is_a?(Hash) ? stringify_hash(entry) : entry }
          else
            child
          end
      end
    end

    private_class_method def normalize_attachment_workspace(value)
      stringify_hash(value).except(*stringify_hash(value).keys.grep(/\Alogical_workspace_/))
    end
  end
end
