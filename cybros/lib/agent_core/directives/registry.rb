module AgentCore
  module Directives
    class Registry
      def initialize(definitions: [])
        @definitions =
          Array(definitions).map do |definition|
            case definition
            when DirectiveDefinition
              definition
            when Hash
              h = AgentCore::Utils.symbolize_keys(definition)
              DirectiveDefinition.new(
                type: h.fetch(:type),
                description: h.fetch(:description, nil),
                aliases: h.fetch(:aliases, nil),
              )
            else
              ValidationError.raise!(
                "Invalid directive definition: #{definition.inspect}",
                code: "agent_core.directives.registry.invalid_directive_definition",
                details: { definition_class: definition.class.name },
              )
            end
          end
      end

      def definitions = @definitions

      def types
        definitions.map(&:type).map { |t| t.to_s.strip }.reject(&:empty?).uniq
      end

      def type_aliases
        definitions.each_with_object({}) do |definition, out|
          canonical = definition.type.to_s.strip
          next if canonical.empty?

          Array(definition.aliases).each do |alias_name|
            token = alias_name.to_s.strip
            next if token.empty?

            out[token] ||= canonical
          end
        end
      end

      def instructions_text
        lines = definitions.map(&:instruction_line).map(&:strip).reject(&:empty?)
        return "" if lines.empty?

        [
          "Allowed directive types:",
          *lines.map { |line| "- #{line}" },
        ].join("\n")
      end
    end
  end
end
