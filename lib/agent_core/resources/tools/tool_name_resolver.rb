# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      # Resolves model-provided tool names to canonical registry names.
      #
      # This is intentionally conservative:
      # - Exact match first
      # - Explicit alias table
      # - Optional normalize fallback (disabled by default at runtime)
      module ToolNameResolver
        Resolution = Data.define(:requested_name, :resolved_name, :method) do
          def changed?
            requested_name != resolved_name
          end
        end

        DEFAULT_ALIASES = {
          # MemoryTools (canonical: memory_search/memory_store/memory_forget)
          "memory.search" => "memory_search",
          "memory.store" => "memory_store",
          "memory.forget" => "memory_forget",
          "memory-search" => "memory_search",
          "memory-store" => "memory_store",
          "memory-forget" => "memory_forget",

          # SkillsTools (canonical: skills_list/skills_load/skills_read_file)
          "skills.list" => "skills_list",
          "skills.load" => "skills_load",
          "skills.read_file" => "skills_read_file",
          "skills-list" => "skills_list",
          "skills-load" => "skills_load",
          "skills-read-file" => "skills_read_file",

          # SubagentTools (canonical: subagent_spawn/subagent_poll)
          "subagent.spawn" => "subagent_spawn",
          "subagent.poll" => "subagent_poll",
          "subagent-spawn" => "subagent_spawn",
          "subagent-poll" => "subagent_poll",
        }.freeze

        module_function

        def resolve(requested_name, include_check:, aliases: {}, enable_normalize_fallback: false, normalize_index: nil)
          requested = requested_name.to_s.strip
          return Resolution.new(requested_name: requested, resolved_name: requested, method: :missing) if requested.empty?

          include_check = include_check || ->(_name) { false }

          return Resolution.new(requested_name: requested, resolved_name: requested, method: :exact) if include_check.call(requested)

          merged_aliases = merge_aliases(aliases)
          aliased = merged_aliases[requested]
          if aliased && include_check.call(aliased)
            return Resolution.new(requested_name: requested, resolved_name: aliased, method: :alias)
          end

          if enable_normalize_fallback
            normalize_index = nil unless normalize_index.is_a?(Hash)
            normalized_key = normalize_key(requested)
            normalized_name = normalize_index && normalized_key && !normalized_key.empty? ? normalize_index[normalized_key] : nil

            if normalized_name && normalized_name != requested && include_check.call(normalized_name)
              return Resolution.new(requested_name: requested, resolved_name: normalized_name, method: :normalized)
            end
          end

          Resolution.new(requested_name: requested, resolved_name: requested, method: :unknown)
        rescue StandardError
          requested = requested_name.to_s
          Resolution.new(requested_name: requested, resolved_name: requested, method: :unknown)
        end

        def merge_aliases(extra)
          extra = normalize_aliases_hash(extra)
          return DEFAULT_ALIASES if extra.empty?

          DEFAULT_ALIASES.merge(extra)
        rescue StandardError
          DEFAULT_ALIASES
        end

        def normalize_key(name)
          s = name.to_s.strip
          return "" if s.empty?

          s = s.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
          s = s.gsub(/([a-z\d])([A-Z])/, '\1_\2')
          s = s.gsub(/[^A-Za-z0-9]+/, "_")
          s = s.downcase
          s = s.gsub(/\A_+|_+\z/, "")
          s
        rescue StandardError
          name.to_s.strip.downcase
        end

        def build_normalize_index(tool_names)
          collisions = Hash.new { |h, k| h[k] = [] }
          index = {}

          Array(tool_names).each do |name|
            canonical = name.to_s.strip
            next if canonical.empty?

            key = normalize_key(canonical)
            next if key.empty?

            existing = index[key]
            if existing && existing != canonical
              collisions[key] |= [existing, canonical]
              next
            end

            index[key] = canonical
          end

          if collisions.any?
            lines =
              collisions
                .first(5)
                .map do |key, names|
                  sample = Array(names).uniq.first(10).map(&:inspect).join(", ")
                  "key=#{key.inspect} names=[#{sample}]"
                end

            raise ToolNameConflictError.new(
              "Tool name normalize collisions:\n#{lines.join("\n")}",
              existing_source: :tools_registry,
              new_source: :tools_registry,
              details: { collision_keys: collisions.keys.first(50) },
            )
          end

          index
        end

        def normalize_aliases_hash(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(k, v), out|
            key = k.to_s.strip
            val = v.to_s.strip
            next if key.empty? || val.empty?

            out[key] = val
          end
        rescue StandardError
          {}
        end
        private_class_method :normalize_aliases_hash
      end
    end
  end
end
