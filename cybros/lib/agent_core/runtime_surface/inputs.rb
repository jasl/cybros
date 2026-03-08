module AgentCore
  module RuntimeSurface
    module Inputs
      PrepareTurn =
        Data.define(
          :prompt,
          :context,
          :budget,
          :capabilities,
          :helpers,
        )

      CompactContext =
        Data.define(
          :context_window,
          :budget,
          :capabilities,
          :helpers,
        )

      ReviewToolCall =
        Data.define(
          :tool_call,
          :context,
          :capabilities,
          :risk_hints,
          :helpers,
        )

      ProjectToolResult =
        Data.define(
          :tool_call,
          :result_meta,
          :preview,
          :artifact_refs,
          :context,
          :budget,
          :helpers,
        )

      FinalizeOutput =
        Data.define(
          :draft_output,
          :context,
          :budget,
          :helpers,
        )

      HandleError =
        Data.define(
          :error,
          :stage,
          :context,
          :budget,
          :helpers,
        )
    end
  end
end
