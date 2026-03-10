# frozen_string_literal: true

module Cybros
  module Agents
    module Default
      class Application
        attr_reader :source_root, :host, :port

        def initialize(
          source_root:,
          host: "127.0.0.1",
          port: 0,
          deployment_key: "default",
          deployment_fingerprint: "deployment:bundled-default",
          required_bearer: nil
        )
          @source_root = Pathname.new(source_root.to_s)
          @host = host
          @port = Integer(port)
          @deployment_key = deployment_key.to_s
          @deployment_fingerprint = deployment_fingerprint.to_s
          @required_bearer = required_bearer
          @rpc_server = nil
        end

        def start
          @rpc_server ||= RPCServer.new(application: self, host: host, port: port, required_bearer: @required_bearer).start
          self
        end

        def shutdown
          @rpc_server&.shutdown
          @rpc_server = nil
        end

        def rpc_url
          @rpc_server&.rpc_url
        end

        def manifest
          @manifest ||= Manifest.load!(source_root: source_root)
        end

        def identity
          @identity ||= Identity.new(
            manifest: manifest,
            deployment_key: @deployment_key,
            deployment_fingerprint: @deployment_fingerprint,
          ).to_h
        end

        def supported_methods
          identity.fetch("supported_methods")
        end

        def call(method_name:, params:)
          RPCDispatcher.new(application: self).dispatch(method_name: method_name, params: params)
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
            prompt_text("system"),
          ].join("\n\n")
        end

        private

        def safe_join(relative)
          candidate = source_root.join(relative.to_s).expand_path
          root = source_root.expand_path
          return candidate if candidate == root || candidate.to_s.start_with?(root.to_s + File::SEPARATOR)

          raise "prompt path escapes bundled default source root"
        end
      end

      class CLI
        def self.run(argv)
          options = {
            host: "127.0.0.1",
            port: 4321,
            source_root: File.expand_path("../../..", __dir__),
            deployment_key: "default",
            deployment_fingerprint: "deployment:bundled-default",
            required_bearer: nil,
          }

          OptionParser.new do |parser|
            parser.on("--host HOST") { |value| options[:host] = value }
            parser.on("--port PORT") { |value| options[:port] = Integer(value) }
            parser.on("--source-root PATH") { |value| options[:source_root] = value }
            parser.on("--deployment-key KEY") { |value| options[:deployment_key] = value }
            parser.on("--deployment-fingerprint FINGERPRINT") { |value| options[:deployment_fingerprint] = value }
            parser.on("--bearer TOKEN") { |value| options[:required_bearer] = value }
          end.parse!(argv)

          application =
            Application.new(
              source_root: options[:source_root],
              host: options[:host],
              port: options[:port],
              deployment_key: options[:deployment_key],
              deployment_fingerprint: options[:deployment_fingerprint],
              required_bearer: options[:required_bearer],
            ).start

          puts "bundled default agent listening on #{application.rpc_url}"

          Signal.trap("INT") { application.shutdown; exit 0 }
          Signal.trap("TERM") { application.shutdown; exit 0 }
          sleep
        ensure
          application&.shutdown
        end
      end
    end
  end
end
