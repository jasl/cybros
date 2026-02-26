module AgentCore
  # Structured "directives envelope" output helpers.
  #
  # Provides:
  # - response_format JSON schema / JSON object fallbacks
  # - parsing + validation + normalization
  # - a small runner with retries ("repair") for brittle models
  module Directives
    DEFAULT_MODES = %i[json_schema json_object prompt_only].freeze
    DEFAULT_REPAIR_RETRY_COUNT = 1

    ENVELOPE_OUTPUT_INSTRUCTIONS = <<~TEXT.strip
      Return a single JSON object and nothing else (no Markdown, no code fences).

      JSON shape:
      - assistant_text: String (always present)
      - directives: Array (always present)
      - Each directive: { type: String, payload: Object }
    TEXT
  end
end
