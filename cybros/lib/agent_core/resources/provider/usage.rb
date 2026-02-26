module AgentCore
  module Resources
    module Provider
      # Token usage information.
      class Usage
        attr_reader :input_tokens, :output_tokens, :cache_creation_tokens, :cache_read_tokens

        def initialize(input_tokens: 0, output_tokens: 0, cache_creation_tokens: 0, cache_read_tokens: 0)
          @input_tokens = input_tokens
          @output_tokens = output_tokens
          @cache_creation_tokens = cache_creation_tokens
          @cache_read_tokens = cache_read_tokens
        end

        def total_tokens
          input_tokens + output_tokens
        end

        def to_h
          {
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_creation_tokens: cache_creation_tokens,
            cache_read_tokens: cache_read_tokens,
            total_tokens: total_tokens,
          }
        end

        # Combine two Usage objects (for aggregation across turns).
        def +(other)
          Usage.new(
            input_tokens: input_tokens + other.input_tokens,
            output_tokens: output_tokens + other.output_tokens,
            cache_creation_tokens: cache_creation_tokens + other.cache_creation_tokens,
            cache_read_tokens: cache_read_tokens + other.cache_read_tokens
          )
        end
      end
    end
  end
end
