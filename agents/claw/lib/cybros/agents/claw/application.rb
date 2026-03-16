require "digest"
require "json"
require "net/http"
require "pathname"
require "securerandom"
require "uri"
require "yaml"
require_relative "tools/web_provider"

module Cybros
  module Agents
    module Claw
      class Application
        WORKSPACE_PROMPT_FILES = {
          "agent" => "AGENTS.md",
          "soul" => "SOUL.md",
          "user" => "USER.md",
        }.freeze

        attr_reader :source_root, :workspace_root, :required_bearer

        def initialize(
          source_root: Rails.root,
          workspace_root: ENV["CLAW_WORKSPACE_ROOT"],
          deployment_key: ENV.fetch("CLAW_DEPLOYMENT_KEY", "claw"),
          deployment_fingerprint: ENV.fetch("CLAW_DEPLOYMENT_FINGERPRINT", "deployment:bundled-claw"),
          required_bearer: ENV.fetch("CLAW_REQUIRED_BEARER", "secret://agent"),
          web_search_backend: ENV.fetch("CLAW_WEB_SEARCH_BACKEND", "duckduckgo_html"),
          web_search_endpoint: ENV["CLAW_WEB_SEARCH_ENDPOINT"]
        )
          @source_root = Pathname.new(source_root.to_s)
          @workspace_root = workspace_root.present? ? Pathname.new(workspace_root.to_s) : nil
          @deployment_key = deployment_key.to_s
          @deployment_fingerprint = deployment_fingerprint.to_s
          @required_bearer = required_bearer
          @web_search_backend = web_search_backend.to_s
          @web_search_endpoint = web_search_endpoint
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
          @agent_capabilities_version ||= begin
            payload = {
              "supported_methods" => supported_methods,
              "agent_tool_catalog" => agent_tool_catalog
            }
            digest = Digest::SHA256.hexdigest(JSON.generate(payload)).first(16)
            "claw-agent-capabilities:#{digest}"
          end
        end

        def web_provider
          @web_provider ||= Tools::WebProvider.new(backend: @web_search_backend, search_endpoint: @web_search_endpoint)
        end

        def web_tools_enabled?
          web_provider.enabled?
        end

        def agent_tool_catalog
          @agent_tool_catalog ||= build_agent_tool_catalog.freeze
        end

        def call(method_name:, params:)
          RpcDispatcher.new(application: self).dispatch(method_name: method_name, params: params)
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
          workspace_prompt_path = workspace_prompt_path_for(prompt_key)
          return workspace_prompt_path.read if workspace_prompt_path&.file?

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

        def build_agent_tool_catalog
          tool_names = %w[
            read
            write
            edit
            apply_patch
            glob
            search
            exec
            memory_search
            memory_get
            memory_store
            skills_load
            skills_read_file
            skills_catalog_list
            skills_install
          ]
          tool_names.concat(%w[web_search web_fetch]) if web_tools_enabled?

          tool_names.map do |tool_name|
            {
              "logical_tool_name" => tool_name,
              "implementation_ref" => "claw:#{tool_name}",
              "execution_mode" => "serial"
            }
          end
        end

        def safe_join(relative)
          candidate = source_root.join(relative.to_s).expand_path
          root = source_root.expand_path
          return candidate if candidate == root || candidate.to_s.start_with?(root.to_s + File::SEPARATOR)

          raise "prompt path escapes bundled claw source root"
        end

        def workspace_prompt_path_for(prompt_key)
          filename = WORKSPACE_PROMPT_FILES[prompt_key.to_s]
          return nil if filename.blank? || workspace_root.nil?

          candidate = workspace_root.join(filename).expand_path
          root = workspace_root.expand_path
          return candidate if candidate == root || candidate.to_s.start_with?(root.to_s + File::SEPARATOR)

          raise "prompt path escapes live workspace root"
        end

        def sanitize_attachment_filename(filename)
          filename.to_s.gsub(/[^a-zA-Z0-9.\-_]+/, "_")
        end
      end
    end
  end
end
