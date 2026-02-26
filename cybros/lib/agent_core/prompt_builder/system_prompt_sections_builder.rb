module AgentCore
  module PromptBuilder
    module SystemPromptSectionsBuilder
      Result = Data.define(:prefix_text, :tail_text, :full_text, :sections)
      Section = Data.define(:id, :stability, :order, :content, :metadata)

      DEFAULT_SECTION_CONFIG = {
        "safety" => { enabled: true, order: 5, stability: :prefix, prompt_modes: %i[full minimal] },
        "tooling" => { enabled: true, order: 6, stability: :prefix, prompt_modes: %i[full] },
        "workspace" => { enabled: true, order: 30, stability: :prefix, prompt_modes: %i[full] },
        "available_skills" => { enabled: true, order: 800, stability: :prefix, prompt_modes: %i[full] },
        "channel" => { enabled: true, order: 860, stability: :tail, prompt_modes: %i[full] },
        "time" => { enabled: true, order: 870, stability: :tail, prompt_modes: %i[full] },
        "memory_relevant_context" => { enabled: true, order: 900, stability: :tail, prompt_modes: %i[full minimal] },
      }.freeze

      FORCED_TAIL_SECTION_IDS = %w[memory_relevant_context time channel].freeze

      module_function

      def build(context:)
        context = context.is_a?(Context) ? context : Context.new(**(context || {}))

        sections = []
        idx = 0

        base = substitute_variables(context.system_prompt.to_s, context.variables)
        sections << Section.new(id: "base_system_prompt", stability: :prefix, order: 0, content: base.to_s, metadata: {})

        add_builtin_section(sections, id: "safety", context: context, content: build_safety_fragment)
        add_builtin_section(sections, id: "tooling", context: context, content: build_tooling_fragment)

        workspace_fragment = build_workspace_fragment(context)
        add_builtin_section(sections, id: "workspace", context: context, content: workspace_fragment)

        Array(context.prompt_injection_items).each do |item|
          next unless item.respond_to?(:system_section?) && item.system_section?
          next if item.respond_to?(:allowed_in_prompt_mode?) && !item.allowed_in_prompt_mode?(context.prompt_mode)

          content = item.content.to_s
          next if content.strip.empty?

          if item.respond_to?(:substitute_variables) && item.substitute_variables == true
            content = substitute_variables(content, context.variables)
          end

          stability = stability_for_item(item)
          order = item.order.to_i

          id =
            if item.respond_to?(:id) && item.id.to_s.strip != ""
              "prompt_injection:#{item.id}"
            else
              idx += 1
              "prompt_injection:#{idx}"
            end

          md = item.respond_to?(:metadata) && item.metadata.is_a?(Hash) ? item.metadata : {}

          sections << Section.new(id: id, stability: stability, order: order, content: content.to_s, metadata: md)
        end

        skills_fragment = build_skills_fragment(context)
        add_builtin_section(sections, id: "available_skills", context: context, content: skills_fragment)

        channel_fragment = build_channel_fragment(context)
        add_builtin_section(sections, id: "channel", context: context, content: channel_fragment)

        time_fragment = build_time_fragment(context)
        add_builtin_section(sections, id: "time", context: context, content: time_fragment)

        memory_fragment = build_memory_fragment(context)
        add_builtin_section(sections, id: "memory_relevant_context", context: context, content: memory_fragment)

        prefix_text = join_sections(sections.select { |s| s.stability == :prefix })
        tail_text = join_sections(sections.select { |s| s.stability == :tail })

        full_text =
          if tail_text.strip.empty?
            prefix_text
          elsif prefix_text.strip.empty?
            tail_text
          else
            "#{prefix_text}\n\n#{tail_text}"
          end

        Result.new(
          prefix_text: prefix_text,
          tail_text: tail_text,
          full_text: full_text,
          sections: sections,
        )
      end

      def add_builtin_section(sections, id:, context:, content:)
        cfg, extra_md = effective_section_config(id, context: context)
        return sections unless cfg.fetch(:enabled, true) == true
        return sections unless section_allowed_in_prompt_mode?(cfg, context.prompt_mode)

        content = content.to_s
        return sections if content.strip.empty?

        stability = cfg.fetch(:stability, :prefix).to_sym
        order = cfg.fetch(:order, 0).to_i
        metadata = extra_md.is_a?(Hash) ? extra_md : {}

        sections << Section.new(
          id: id.to_s,
          stability: stability,
          order: order,
          content: content,
          metadata: metadata,
        )
      rescue StandardError
        sections
      end
      private_class_method :add_builtin_section

      def effective_section_config(id, context:)
        id = id.to_s
        defaults = DEFAULT_SECTION_CONFIG.fetch(id, { enabled: true, order: 0, stability: :prefix, prompt_modes: %i[full minimal] })

        overrides = context.system_prompt_section_overrides
        raw = fetch_section_override(overrides, id)

        cfg = defaults.dup
        cfg[:enabled] = raw[:enabled] if raw.key?(:enabled)
        cfg[:order] = raw[:order] if raw.key?(:order)
        cfg[:prompt_modes] = normalize_prompt_modes(raw[:prompt_modes]) if raw.key?(:prompt_modes)
        cfg[:stability] = normalize_stability(raw[:stability]) if raw.key?(:stability)

        extra_md = {}

        if FORCED_TAIL_SECTION_IDS.include?(id)
          requested = cfg[:stability]
          if requested && requested.to_sym != :tail && raw.key?(:stability)
            extra_md["stability_override_ignored"] = true
            extra_md["requested_stability"] = requested.to_s
            extra_md["forced_stability"] = "tail"
          end
          cfg[:stability] = :tail
        end

        [cfg, extra_md]
      rescue StandardError
        [{ enabled: true, order: 0, stability: :prefix, prompt_modes: %i[full minimal] }, {}]
      end
      private_class_method :effective_section_config

      def fetch_section_override(overrides, id)
        return {} unless overrides.is_a?(Hash)

        raw = overrides[id] || overrides[id.to_sym] || overrides[id.to_s]
        return {} unless raw.is_a?(Hash)

        out = {}
        raw.each do |k, v|
          next unless k.is_a?(String) || k.is_a?(Symbol)

          key = k.to_s.strip.downcase.tr("-", "_").to_sym
          next unless %i[enabled order prompt_modes stability].include?(key)

          out[key] = v
        end
        out
      rescue StandardError
        {}
      end
      private_class_method :fetch_section_override

      def section_allowed_in_prompt_mode?(cfg, prompt_mode)
        modes = cfg.fetch(:prompt_modes, %i[full minimal])
        Array(modes).map(&:to_sym).include?((prompt_mode || :full).to_sym)
      rescue StandardError
        true
      end
      private_class_method :section_allowed_in_prompt_mode?

      def normalize_prompt_modes(value)
        allowed = AgentCore::Resources::PromptInjections::PROMPT_MODES

        Array(value).map do |raw|
          s = raw.to_s.strip.downcase.tr("-", "_")
          s.to_sym
        end.select { |m| allowed.include?(m) }.uniq
      rescue StandardError
        []
      end
      private_class_method :normalize_prompt_modes

      def normalize_stability(value)
        s = value.to_s.strip.downcase.tr("-", "_")
        return :tail if s == "tail"
        :prefix
      rescue StandardError
        :prefix
      end
      private_class_method :normalize_stability

      def build_safety_fragment
        "<safety>\nFollow instructions. Ask before destructive actions. Do not fabricate tool results.\n</safety>"
      rescue StandardError
        ""
      end
      private_class_method :build_safety_fragment

      def build_tooling_fragment
        "<tooling>\nUse tools via tool_calls only when needed. Arguments must be valid JSON and match the provided schema. Do not call tools that are not provided.\n</tooling>"
      rescue StandardError
        ""
      end
      private_class_method :build_tooling_fragment

      def build_workspace_fragment(context)
        attrs = context.execution_context.attributes
        cwd = attrs[:cwd].to_s.strip
        workspace_dir = attrs[:workspace_dir].to_s.strip

        lines = []
        lines << "cwd: #{cwd}" unless cwd.empty?
        lines << "workspace_dir: #{workspace_dir}" unless workspace_dir.empty?
        return "" if lines.empty?

        "<workspace>\n#{lines.join("\n")}\n</workspace>"
      rescue StandardError
        ""
      end
      private_class_method :build_workspace_fragment

      def build_channel_fragment(context)
        channel = context.execution_context.attributes[:channel].to_s
        channel = channel.lines.first.to_s.strip
        channel = AgentCore::Utils.truncate_utf8_bytes(channel, max_bytes: 128)
        return "" if channel.empty?

        "<channel>\nname: #{channel}\n</channel>"
      rescue StandardError
        ""
      end
      private_class_method :build_channel_fragment

      def build_time_fragment(context)
        attrs = context.execution_context.attributes
        explicit = attrs[:system_prompt_now_utc].to_s.strip
        now_utc =
          if explicit.empty?
            context.execution_context.clock.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          else
            explicit
          end

        "<time>\nnow_utc: #{now_utc}\n</time>"
      rescue StandardError
        ""
      end
      private_class_method :build_time_fragment

      def build_skills_fragment(context)
        store = context.skills_store
        return "" unless store

        Resources::Skills::PromptFragment.available_skills_xml(
          store: store,
          include_location: context.include_skill_locations,
        )
      rescue StandardError
        ""
      end
      private_class_method :build_skills_fragment

      def build_memory_fragment(context)
        memory_results = Array(context.memory_results)
        return "" if memory_results.empty?

        memory_text = memory_results.map { |e| e.respond_to?(:content) ? e.content.to_s : e.to_s }.join("\n\n")
        "<relevant_context>\n#{memory_text}\n</relevant_context>"
      rescue StandardError
        ""
      end
      private_class_method :build_memory_fragment

      def join_sections(sections)
        out = +""
        Array(sections)
          .each_with_index
          .sort_by { |(section, i)| [section.order.to_i, i] }
          .each do |(section, _)|
            content = section.content.to_s
            next if content.strip.empty?

            out = out.empty? ? content : "#{out}\n\n#{content}"
          end
        out
      rescue StandardError
        ""
      end
      private_class_method :join_sections

      def substitute_variables(template, variables)
        out = template.to_s.dup
        (variables || {}).each do |key, value|
          out = out.gsub("{{#{key}}}", value.to_s)
        end
        out
      rescue StandardError
        template.to_s
      end
      private_class_method :substitute_variables

      def stability_for_item(item)
        md = item.respond_to?(:metadata) ? item.metadata : nil
        raw =
          if md.is_a?(Hash)
            md[:stability]
          end

        value = raw.to_s.strip.downcase
        value = value.tr("-", "_")
        value == "tail" ? :tail : :prefix
      rescue StandardError
        :prefix
      end
      private_class_method :stability_for_item
    end
  end
end
