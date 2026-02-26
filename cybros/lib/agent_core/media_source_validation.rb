module AgentCore
  # Shared validation logic for media content blocks (image, document, audio).
  #
  # Provides source_type-based validation:
  #   :base64 — requires data + media_type
  #   :url    — requires url
  module MediaSourceValidation
    VALID_SOURCE_TYPES = %i[base64 url].freeze

    private

    def validate_media_source!
      cfg = AgentCore.config

      ValidationError.raise!(
        "source_type is required",
        code: "agent_core.media_source_validation.source_type_is_required",
      ) if source_type.nil?
      unless VALID_SOURCE_TYPES.include?(source_type)
        ValidationError.raise!(
          "source_type must be one of: #{VALID_SOURCE_TYPES.join(", ")} (got #{source_type.inspect})",
          code: "agent_core.media_source_validation.source_type_must_be_one_of_got",
          details: { source_type: source_type&.to_s, allowed_source_types: VALID_SOURCE_TYPES.map(&:to_s).sort },
        )
      end

      case source_type
      when :base64
        ValidationError.raise!(
          "data is required for base64 source",
          code: "agent_core.media_source_validation.data_is_required_for_base64_source",
        ) if data.nil? || data.empty?
        ValidationError.raise!(
          "media_type is required for base64 source",
          code: "agent_core.media_source_validation.media_type_is_required_for_base64_source",
        ) if media_type.nil? || media_type.empty?
      when :url
        ValidationError.raise!(
          "url sources are disabled",
          code: "agent_core.media_source_validation.url_sources_are_disabled",
        ) unless cfg.allow_url_media_sources
        ValidationError.raise!(
          "url is required for url source",
          code: "agent_core.media_source_validation.url_is_required_for_url_source",
        ) if url.nil? || url.empty?

        if (allowed_schemes = cfg.allowed_media_url_schemes)
          allowed = Array(allowed_schemes).map(&:to_s).map(&:downcase)
          require "uri"
          uri = begin
            URI.parse(url.to_s)
          rescue URI::InvalidURIError => e
            ValidationError.raise!(
              "url is invalid: #{e.message}",
              code: "agent_core.media_source_validation.url_is_invalid",
            )
          end
          scheme = uri.scheme&.downcase
          unless scheme && allowed.include?(scheme)
            ValidationError.raise!(
              "url scheme must be one of: #{allowed.join(", ")} (got #{scheme.inspect})",
              code: "agent_core.media_source_validation.url_scheme_must_be_one_of_got",
              details: { scheme: scheme, allowed_schemes: allowed.sort },
            )
          end
        end
      end

      if (validator = cfg.media_source_validator)
        allowed = validator.call(self)
        ValidationError.raise!(
          "media source rejected by policy",
          code: "agent_core.media_source_validation.media_source_rejected_by_policy",
        ) unless allowed
      end
    end
  end
end
