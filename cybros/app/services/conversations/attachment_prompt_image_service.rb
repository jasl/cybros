require "uri"

module Conversations
  class AttachmentPromptImageService
    IMAGE_FORWARDING_ERROR = "could not be forwarded to the model as an image and remains available in the workspace.".freeze

    def self.build(attachment:, url_options: nil)
      new(attachment: attachment, url_options: url_options).build
    end

    def initialize(attachment:, url_options: nil)
      @attachment = attachment
      @url_options = url_options
    end

    def build
      return blank_payload unless attachment.image?

      representation = attachment.prompt_image_representation
      return blank_payload unless representation

      processed = representation.processed

      {
        "prompt_image_url" => helpers.rails_storage_proxy_url(processed, **resolved_url_options),
        "media_type" => processed.content_type,
        "prompt_image_error" => nil,
      }
    rescue StandardError
      {
        "prompt_image_url" => nil,
        "media_type" => nil,
        "prompt_image_error" => "Attachment `#{attachment.filename}` #{IMAGE_FORWARDING_ERROR}",
      }
    end

    private

      attr_reader :attachment, :url_options

      def blank_payload
        {
          "prompt_image_url" => nil,
          "media_type" => nil,
          "prompt_image_error" => nil,
        }
      end

      def helpers
        Rails.application.routes.url_helpers
      end

      def resolved_url_options
        return url_options if url_options.present?

        base_url = Current.base_url.presence || ENV["CYBROS_BASE_URL"].to_s.presence

        if base_url.present?
          uri = URI.parse(base_url)
          {
            protocol: uri.scheme,
            host: uri.host,
            port: default_port?(uri) ? nil : uri.port,
          }.compact
        else
          options = ActionMailer::Base.default_url_options || {}
          {
            protocol: options[:protocol].presence || options["protocol"].presence || "http",
            host: options[:host].presence || options["host"].presence,
            port: options[:port].presence || options["port"].presence,
          }.compact
        end
      rescue URI::InvalidURIError
        {}
      end

      def default_port?(uri)
        (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
      end
  end
end
