# frozen_string_literal: true

module AgentCore
  # Document content block (PDF, plain text, HTML, CSV, etc.).
  class DocumentContent
    include MediaSourceValidation

    # Text-based MIME types where data can be counted as text tokens.
    TEXT_MEDIA_TYPES = %w[text/plain text/html text/csv text/markdown].freeze

    attr_reader :source_type, :data, :media_type, :url, :filename, :title

    def initialize(source_type:, data: nil, media_type: nil, url: nil, filename: nil, title: nil)
      @source_type = source_type&.to_sym
      @data = data.is_a?(String) ? data.dup.freeze : data
      @media_type = Utils.normalize_mime_type(media_type)&.freeze
      @url = url.is_a?(String) ? url.dup.freeze : url
      @filename = filename.is_a?(String) ? filename.dup.freeze : filename
      @title = title.is_a?(String) ? title.dup.freeze : title
      validate_media_source!
    end

    def type = :document

    def effective_media_type
      media_type || Utils.infer_mime_type(filename || Utils.filename_from_url(url))
    end

    # Whether the document's media_type is a text-based format.
    def text_based?
      TEXT_MEDIA_TYPES.include?(effective_media_type)
    end

    # Returns text content for text-based documents (as provided in data), nil otherwise.
    def text
      return nil unless text_based? && source_type == :base64 && data

      data
    end

    def to_h
      h = { type: :document, source_type: source_type }
      h[:data] = data if data
      h[:media_type] = media_type if media_type
      h[:url] = url if url
      h[:filename] = filename if filename
      h[:title] = title if title
      h
    end

    def ==(other)
      other.is_a?(DocumentContent) &&
        source_type == other.source_type &&
        data == other.data &&
        url == other.url &&
        media_type == other.media_type &&
        filename == other.filename &&
        title == other.title
    end

    def self.from_h(hash)
      ValidationError.raise!(
        "document content must be a Hash (got #{hash.class})",
        code: "agent_core.document_content.document_content_must_be_a_hash_got",
        details: { value_class: hash.class.name },
      ) unless hash.is_a?(Hash)

      new(
        source_type: hash.fetch("source_type", hash.fetch(:source_type, nil)),
        data: hash.fetch("data", hash.fetch(:data, nil)),
        media_type: hash.fetch("media_type", hash.fetch(:media_type, nil)),
        url: hash.fetch("url", hash.fetch(:url, nil)),
        filename: hash.fetch("filename", hash.fetch(:filename, nil)),
        title: hash.fetch("title", hash.fetch(:title, nil)),
      )
    end
  end
end
