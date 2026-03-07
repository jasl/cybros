import { describe, expect, test } from "bun:test"
import { deriveConversationControlsState } from "../../app/javascript/lib/conversation_controls_state"

describe("deriveConversationControlsState", () => {
  test("keeps stop bound to a non-tail stoppable bubble when tail is not stoppable", () => {
    const state = deriveConversationControlsState([
      {
        nodeId: "agent_1",
        isTail: false,
        actionPolicy: {
          actions: {
            stop: { available: true },
            retry: { available: false },
          },
        },
      },
      {
        nodeId: "agent_2",
        isTail: true,
        actionPolicy: {
          actions: {
            stop: { available: false },
            retry: { available: false },
          },
        },
      },
    ])

    expect(state).toEqual({
      activeNodeId: "agent_1",
      showStop: true,
      lastErroredNodeId: null,
      showRetry: false,
    })
  })

  test("keeps retry tied to the tail bubble", () => {
    const state = deriveConversationControlsState([
      {
        nodeId: "agent_1",
        isTail: false,
        actionPolicy: {
          actions: {
            stop: { available: false },
            retry: { available: true },
          },
        },
      },
      {
        nodeId: "agent_2",
        isTail: true,
        actionPolicy: {
          actions: {
            stop: { available: false },
            retry: { available: true },
          },
        },
      },
    ])

    expect(state).toEqual({
      activeNodeId: null,
      showStop: false,
      lastErroredNodeId: "agent_2",
      showRetry: true,
    })
  })
})
