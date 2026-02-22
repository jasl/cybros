# frozen_string_literal: true

module AgentCore
  module Resources
    module ChatHistory
      # Normalize various inputs into a ChatHistory adapter.
      #
      # @param input [nil, Array, Base, Enumerable]
      # @return [Base]
      def self.wrap(input)
        case input
        when nil
          InMemory.new
        when Base
          input
        when Array
          InMemory.new(input)
        else
          if input.respond_to?(:each)
            InMemory.new(input.to_a)
          else
            raise ValidationError, "Unsupported chat history: #{input.class}. " \
                                 "Expected nil, Array, Enumerable, or ChatHistory::Base."
          end
        end
      end
    end
  end
end
