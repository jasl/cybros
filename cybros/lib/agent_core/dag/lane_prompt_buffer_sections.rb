require "digest"

module AgentCore
  module DAG
    class LanePromptBufferSections
      Section = Data.define(:buffer_name, :content, :entry_ids, :estimated_tokens, :order, :metadata)

      BUFFER_ORDERS = {
        "summaries" => 820,
        "working_notes" => 830,
        "handoff" => 840,
      }.freeze
      DEFAULT_ORDER = 850

      def initialize(lane:)
        @lane = lane
      end

      def prompt_injection_items(excluded_buffer_names: [])
        sections(excluded_buffer_names: excluded_buffer_names).map do |section|
          AgentCore::Resources::PromptInjections::Item.new(
            target: :system_section,
            id: "lane_prompt_buffer:#{section.buffer_name}",
            order: section.order,
            content: section.content,
            metadata: section.metadata.merge(stability: "tail"),
          )
        end
      end

      def fingerprint_payload(excluded_buffer_names: [])
        sections(excluded_buffer_names: excluded_buffer_names).map do |section|
          {
            buffer_name: section.buffer_name,
            entry_ids: section.entry_ids,
            estimated_tokens: section.estimated_tokens,
            sha256: Digest::SHA256.hexdigest(section.content.to_s),
          }
        end
      end

      def sections(excluded_buffer_names: [])
        grouped_entries =
          filtered_entries(excluded_buffer_names: excluded_buffer_names)
            .group_by(&:buffer_name)
            .sort_by { |(buffer_name, _)| [BUFFER_ORDERS.fetch(buffer_name, DEFAULT_ORDER), buffer_name.to_s] }

        grouped_entries.filter_map do |buffer_name, entries|
          rendered_content = entries.map { |entry| entry.content.to_s.strip }.reject(&:blank?).join("\n\n")
          next if rendered_content.blank?

          entry_ids = entries.map(&:id)
          Section.new(
            buffer_name: buffer_name.to_s,
            content: wrap_section(buffer_name, rendered_content),
            entry_ids: entry_ids,
            estimated_tokens: entries.sum { |entry| entry.estimated_tokens.to_i },
            order: BUFFER_ORDERS.fetch(buffer_name.to_s, DEFAULT_ORDER),
            metadata: {
              source: "lane_prompt_buffer",
              buffer_name: buffer_name.to_s,
              entry_ids: entry_ids,
              entry_count: entries.length,
            },
          )
        end
      end

      private

        def filtered_entries(excluded_buffer_names: [])
          excluded = Array(excluded_buffer_names).map { |name| name.to_s.strip }.reject(&:empty?).uniq
          return ordered_entries if excluded.empty?

          ordered_entries.reject { |entry| excluded.include?(entry.buffer_name.to_s) }
        rescue StandardError
          ordered_entries
        end

        def ordered_entries
          return [] unless @lane.respond_to?(:lane_prompt_buffer_entries)

          @lane.lane_prompt_buffer_entries.ordered.to_a
        rescue StandardError
          []
        end

        def wrap_section(buffer_name, rendered_content)
          %(<lane_prompt_buffer name="#{buffer_name}">\n#{rendered_content}\n</lane_prompt_buffer>)
        end
    end
  end
end
