module AgentCore
  # Image content block.
  #
  # Supports both base64-encoded data and URL references.
  # Provider layer converts to API-specific format (Anthropic, OpenAI, Google).
  class ImageContent
    include MediaSourceValidation

    attr_reader :source_type, :data, :media_type, :url

    def initialize(source_type:, data: nil, media_type: nil, url: nil)
      @source_type = source_type&.to_sym
      @data = data.is_a?(String) ? data.dup.freeze : data
      @media_type = Utils.normalize_mime_type(media_type)&.freeze
      @url = url.is_a?(String) ? url.dup.freeze : url
      validate_media_source!
    end

    def type = :image

    def effective_media_type
      media_type || Utils.infer_mime_type(Utils.filename_from_url(url))
    end

    def to_h
      h = { type: :image, source_type: source_type }
      h[:data] = data if data
      h[:media_type] = media_type if media_type
      h[:url] = url if url

      h
    end

    def ==(other)
      other.is_a?(ImageContent) &&
        source_type == other.source_type &&
        data == other.data &&
        url == other.url &&
        media_type == other.media_type
    end

    def self.from_h(hash)
      ValidationError.raise!(
        "image content must be a Hash (got #{hash.class})",
        code: "agent_core.image_content.image_content_must_be_a_hash_got",
        details: { value_class: hash.class.name },
      ) unless hash.is_a?(Hash)

      new(
        source_type: hash.fetch("source_type", hash.fetch(:source_type, nil)),
        data: hash.fetch("data", hash.fetch(:data, nil)),
        media_type: hash.fetch("media_type", hash.fetch(:media_type, nil)),
        url: hash.fetch("url", hash.fetch(:url, nil)),
      )
    end
  end
end
