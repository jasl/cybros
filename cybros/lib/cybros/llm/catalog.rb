require "yaml"

module Cybros
  module LLM
    class CatalogError < StandardError
      attr_reader :details

      def initialize(message, details: nil)
        super(message)
        @details = details
      end
    end

    module Catalog
      PROVIDER_KEY_RE = /\A[a-z0-9][a-z0-9_-]*\z/.freeze
      MODEL_KEY_RE = /\A[a-z0-9][a-z0-9._-]*\z/.freeze

      module_function

      def effective
        @effective ||= load_effective!
      end

      def reload!
        @effective = load_effective!
      end

      def load_effective!
        sources = resolve_sources
        raw = sources.filter_map { |path| load_yaml_file(path) }.reduce({}) { |acc, h| deep_merge(acc, h) }
        validate!(raw, sources: sources)
        EffectiveCatalog.new(raw: raw, sources: sources)
      end

      def resolve_sources
        default_path = Rails.root.join("config/llm/providers.yml").to_s

        explicit = ENV["CYBROS_LLM_CONFIG_PATH"].to_s.strip
        return [default_path, explicit].uniq if explicit.present? && File.file?(explicit)

        root = ENV["CYBROS_CONFIG_ROOT"].to_s.strip
        if root.present?
          mounted = File.join(root, "llm/providers.yml")
          return [default_path, mounted].uniq if File.file?(mounted)
        end

        [default_path]
      end

      def load_yaml_file(path)
        yaml = File.read(path)
        obj = YAML.safe_load(yaml, aliases: false, permitted_classes: [], permitted_symbols: [], filename: path)
        obj.is_a?(Hash) ? deep_stringify_keys(obj) : {}
      rescue Psych::SyntaxError => e
        raise CatalogError.new("Invalid YAML in #{path}", details: { path: path, error: e.message })
      rescue Errno::ENOENT
        nil
      end

      def validate!(raw, sources:)
        errors = []

        unless raw.is_a?(Hash)
          errors << ["$", "must be a mapping"]
          raise_invalid!(errors, sources: sources)
        end

        version = raw["version"]
        errors << ["$.version", "must be 1"] unless version == 1

        default_model_ref = raw["default_model_ref"].to_s.strip
        errors << ["$.default_model_ref", "must be present"] if default_model_ref.empty?

        providers = raw["providers"]
        unless providers.is_a?(Hash)
          errors << ["$.providers", "must be a mapping"]
          raise_invalid!(errors, sources: sources)
        end

        providers.each do |provider_key, provider|
          pointer = "$.providers.#{provider_key}"
          unless PROVIDER_KEY_RE.match?(provider_key.to_s)
            errors << [pointer, "provider_key is invalid (must match #{PROVIDER_KEY_RE.inspect})"]
          end

          unless provider.is_a?(Hash)
            errors << [pointer, "must be a mapping"]
            next
          end

          display_name = provider["display_name"].to_s.strip
          errors << ["#{pointer}.display_name", "must be present"] if display_name.empty?

          enabled = provider["enabled"]
          errors << ["#{pointer}.enabled", "must be a boolean"] unless enabled == true || enabled == false

          adapter_key = provider["adapter_key"].to_s.strip
          errors << ["#{pointer}.adapter_key", "must be present"] if adapter_key.empty?

          base_url = provider["base_url"].to_s.strip
          errors << ["#{pointer}.base_url", "must be present"] if base_url.empty?

          headers = provider.fetch("headers", {})
          errors << ["#{pointer}.headers", "must be a mapping"] unless headers.is_a?(Hash)

          requires_credential = provider["requires_credential"]
          errors << ["#{pointer}.requires_credential", "must be a boolean"] unless requires_credential == true || requires_credential == false

          credential_type = provider.fetch("credential_type", nil)
          if requires_credential == true
            ct = credential_type.to_s.strip
            errors << ["#{pointer}.credential_type", "must be present when requires_credential is true"] if ct.empty?
          end

          wire_api = provider["wire_api"].to_s
          unless %w[responses chat_completions].include?(wire_api)
            errors << ["#{pointer}.wire_api", "must be 'responses' or 'chat_completions'"]
          end

          transport = provider["transport"].to_s
          if wire_api == "responses"
            unless %w[http_sse websocket auto].include?(transport)
              errors << ["#{pointer}.transport", "must be 'http_sse', 'websocket', or 'auto' for wire_api=responses"]
            end
            responses_path = provider["responses_path"].to_s.strip
            errors << ["#{pointer}.responses_path", "must be present for wire_api=responses"] if responses_path.empty?
          elsif wire_api == "chat_completions"
            errors << ["#{pointer}.transport", "must be 'http' for wire_api=chat_completions"] unless transport == "http"
          end

          envs = provider.fetch("environments", nil)
          if !envs.nil? && !(envs.is_a?(Array) && envs.all? { |v| v.is_a?(String) && v.strip.present? })
            errors << ["#{pointer}.environments", "must be an array of strings when present"]
          end

          if provider.key?("default_model")
            errors << ["#{pointer}.default_model", "is no longer supported; use $.default_model_ref instead"]
          end

          models = provider["models"]
          unless models.is_a?(Hash) && models.any?
            errors << ["#{pointer}.models", "must be a mapping with at least 1 model"]
            next
          end

          models.each do |model_key, model|
            mp = "#{pointer}.models.#{model_key}"
            unless MODEL_KEY_RE.match?(model_key.to_s)
              errors << [mp, "model_key is invalid (must match #{MODEL_KEY_RE.inspect})"]
            end

            unless model.is_a?(Hash)
              errors << [mp, "must be a mapping"]
              next
            end

            dn = model["display_name"].to_s.strip
            errors << ["#{mp}.display_name", "must be present"] if dn.empty?

            api_model = model["api_model"].to_s.strip
            errors << ["#{mp}.api_model", "must be present"] if api_model.empty?

            caps = model["capabilities"]
            unless caps.is_a?(Hash)
              errors << ["#{mp}.capabilities", "must be a mapping"]
              next
            end

            protocol = caps["protocol"].to_s
            unless %w[responses chat_completions].include?(protocol)
              errors << ["#{mp}.capabilities.protocol", "must be 'responses' or 'chat_completions'"]
            end

            ctx = model["context_window_tokens"]
            unless ctx.is_a?(Integer) && ctx.positive?
              errors << ["#{mp}.context_window_tokens", "must be a positive integer"]
            end
          end
        end

        if default_model_ref.present?
          provider_key, model_key = default_model_ref.split("/", 2).map(&:to_s)
          provider = providers[provider_key]

          if provider_key.blank? || model_key.blank?
            errors << ["$.default_model_ref", "must be a provider_key/model_key reference"]
          elsif !provider.is_a?(Hash)
            errors << ["$.default_model_ref", "references missing provider_key: #{provider_key}"]
          else
            models = provider["models"]
            unless models.is_a?(Hash) && models.key?(model_key)
              errors << ["$.default_model_ref", "references missing model_ref: #{default_model_ref}"]
            end
          end
        end

        raise_invalid!(errors, sources: sources) if errors.any?
      end

      def raise_invalid!(errors, sources:)
        message =
          +"LLM catalog validation failed.\n" \
           "Sources:\n" \
           "#{sources.map { |p| "- #{p}" }.join("\n")}\n" \
           "Errors:\n" \
           "#{errors.map { |(ptr, msg)| "- #{ptr}: #{msg}" }.join("\n")}"
        raise CatalogError.new(message, details: { sources: sources, errors: errors })
      end

      def deep_merge(a, b)
        return a unless b.is_a?(Hash)
        return b unless a.is_a?(Hash)

        out = a.dup
        b.each do |k, v|
          if out.key?(k) && out[k].is_a?(Hash) && v.is_a?(Hash)
            out[k] = deep_merge(out[k], v)
          else
            out[k] = v
          end
        end
        out
      end

      def deep_stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), out|
            out[k.to_s] = deep_stringify_keys(v)
          end
        when Array
          value.map { |v| deep_stringify_keys(v) }
        else
          value
        end
      end

      class EffectiveCatalog
        attr_reader :raw, :sources

        def initialize(raw:, sources:)
          @raw = raw
          @sources = sources
        end

        def providers
          raw.fetch("providers")
        end

        def default_model_ref
          raw.fetch("default_model_ref").to_s
        end

        def provider(provider_key)
          providers.fetch(provider_key.to_s)
        end

        def models_for(provider_key)
          provider(provider_key).fetch("models")
        end

        def model(provider_key, model_key)
          models_for(provider_key).fetch(model_key.to_s)
        end

        def enabled_provider_keys_for_env(env)
          env_name = env.to_s
          providers.filter_map do |provider_key, p|
            next unless p.fetch("enabled") == true

            envs = p.fetch("environments", nil)
            next if envs.is_a?(Array) && !envs.include?(env_name)

            provider_key
          end
        end
      end
    end
  end
end
