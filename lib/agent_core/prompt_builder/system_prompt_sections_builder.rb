# frozen_string_literal: true

module AgentCore
  module PromptBuilder
    module SystemPromptSectionsBuilder
      Result = Data.define(:prefix_text, :tail_text, :full_text, :sections)
      Section = Data.define(:id, :stability, :order, :content, :metadata)

      module_function

      def build(context:)
        context = context.is_a?(Context) ? context : Context.new(**(context || {}))

        sections = []
        idx = 0

        base = substitute_variables(context.system_prompt.to_s, context.variables)
        sections << Section.new(id: "base_system_prompt", stability: :prefix, order: 0, content: base.to_s, metadata: {})

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
        if !skills_fragment.to_s.strip.empty?
          sections << Section.new(
            id: "available_skills",
            stability: :prefix,
            order: 800,
            content: skills_fragment.to_s,
            metadata: {},
          )
        end

        memory_fragment = build_memory_fragment(context)
        if !memory_fragment.to_s.strip.empty?
          sections << Section.new(
            id: "memory_relevant_context",
            stability: :tail,
            order: 900,
            content: memory_fragment.to_s,
            metadata: {},
          )
        end

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

