require "json"
require "net/http"
require "pathname"
require "securerandom"
require "uri"
require "yaml"

module Cybros
  module Agents
    module Claw
      class Application
        attr_reader :source_root, :required_bearer

        def initialize(
          source_root: Rails.root,
          deployment_key: ENV.fetch("CLAW_DEPLOYMENT_KEY", "claw"),
          deployment_fingerprint: ENV.fetch("CLAW_DEPLOYMENT_FINGERPRINT", "deployment:bundled-claw"),
          required_bearer: ENV.fetch("CLAW_REQUIRED_BEARER", "secret://agent")
        )
          @source_root = Pathname.new(source_root.to_s)
          @deployment_key = deployment_key.to_s
          @deployment_fingerprint = deployment_fingerprint.to_s
          @required_bearer = required_bearer
        end

        def manifest
          @manifest ||= Manifest.load!(source_root: source_root)
        end

        def identity
          @identity ||= Identity.new(
            manifest: manifest,
            deployment_key: @deployment_key,
            deployment_fingerprint: @deployment_fingerprint
          ).to_h
        end

        def supported_methods
          identity.fetch("supported_methods")
        end

        def agent_capabilities_version
          "claw-agent-capabilities:v1"
        end

        def agent_tool_catalog
          []
        end

        def call(method_name:, params:)
          RPCDispatcher.new(application: self).dispatch(method_name: method_name, params: params)
        end

        def import_attachments(params:)
          attachments = Array(params["attachments"]).select { |attachment| attachment.is_a?(Hash) }

          {
            "imports" =>
              attachments.map do |attachment|
                attachment_id = attachment.fetch("id").to_s
                filename = attachment.fetch("filename").to_s

                {
                  "id" => attachment_id,
                  "remote_ref" => {
                    "kind" => "attachment_import",
                    "locator" => "attachment-import://#{attachment_id}/#{sanitize_attachment_filename(filename)}",
                    "filename" => filename,
                    "content_type" => attachment.fetch("content_type").to_s,
                    "byte_size" => attachment.fetch("byte_size"),
                    "digest" => attachment.fetch("digest").to_s
                  }
                }
              end
          }
        end

        def prompt_text(prompt_key)
          relative = manifest.fetch("prompts").fetch(prompt_key.to_s)
          safe_join(relative).read
        end

        def full_system_prompt
          [
            prompt_text("agent"),
            prompt_text("soul"),
            prompt_text("user"),
            prompt_text("system")
          ].join("\n\n")
        end

        private

        def safe_join(relative)
          candidate = source_root.join(relative.to_s).expand_path
          root = source_root.expand_path
          return candidate if candidate == root || candidate.to_s.start_with?(root.to_s + File::SEPARATOR)

          raise "prompt path escapes bundled claw source root"
        end

        def sanitize_attachment_filename(filename)
          filename.to_s.gsub(/[^a-zA-Z0-9.\-_]+/, "_")
        end
      end
    end
  end
end
