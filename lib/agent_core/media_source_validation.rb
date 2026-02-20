# frozen_string_literal: true

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

      raise ArgumentError, "source_type is required" if source_type.nil?
      unless VALID_SOURCE_TYPES.include?(source_type)
        raise ArgumentError, "source_type must be one of: #{VALID_SOURCE_TYPES.join(", ")} (got #{source_type.inspect})"
      end

      case source_type
      when :base64
        raise ArgumentError, "data is required for base64 source" if data.nil? || data.empty?
        raise ArgumentError, "media_type is required for base64 source" if media_type.nil? || media_type.empty?
      when :url
        raise ArgumentError, "url sources are disabled" unless cfg.allow_url_media_sources
        raise ArgumentError, "url is required for url source" if url.nil? || url.empty?

        if (allowed_schemes = cfg.allowed_media_url_schemes)
          allowed = Array(allowed_schemes).map(&:to_s).map(&:downcase)
          require "uri"
          uri = begin
            URI.parse(url.to_s)
          rescue URI::InvalidURIError => e
            raise ArgumentError, "url is invalid: #{e.message}"
          end
          scheme = uri.scheme&.downcase
          unless scheme && allowed.include?(scheme)
            raise ArgumentError, "url scheme must be one of: #{allowed.join(", ")} (got #{scheme.inspect})"
          end
        end
      end

      if (validator = cfg.media_source_validator)
        allowed = validator.call(self)
        raise ArgumentError, "media source rejected by policy" unless allowed
      end
    end
  end
end
