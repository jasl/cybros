module Cybros
  module Agents
    module Claw
      class ValidationError < StandardError
        attr_reader :code, :details

        def self.raise!(message, code:, details: {})
          raise new(message, code:, details:)
        end

        def initialize(message, code:, details: {})
          @code = code.to_s
          @details = Manifest.deep_stringify(details.is_a?(Hash) ? details : {})
          super(message.to_s)
        end
      end
    end
  end
end
