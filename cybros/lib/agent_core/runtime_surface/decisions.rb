module AgentCore
  module RuntimeSurface
    module Decisions
      Pass = Data.define()

      TurnRewrite = Data.define(:prompt, :metadata)

      ContextCompaction =
        Data.define(
          :kept_items,
          :summaries,
          :externalized_items,
          :metadata,
        )

      ToolCallSuggestion =
        Data.define(
          :action,
          :reason,
          :patched_tool_call,
          :metadata,
        )

      ToolResultProjection =
        Data.define(
          :action,
          :projected_result,
          :reason,
          :metadata,
        )

      FinalOutput = Data.define(:output, :metadata)

      ErrorHandling =
        Data.define(
          :action,
          :output,
          :reason,
          :metadata,
        )
    end
  end
end
