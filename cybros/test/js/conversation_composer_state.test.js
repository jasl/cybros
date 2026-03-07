import { describe, expect, test } from "bun:test"
import { deriveComposerFormState, deriveComposerPreviewText } from "../../app/javascript/lib/conversation_composer_state"

describe("deriveComposerFormState", () => {
  test("uses the steer endpoint when steer mode is selected and available", () => {
    expect(
      deriveComposerFormState({
        railState: {
          running: true,
          queueAvailable: true,
          steerAvailable: true,
          createUrl: "/conversations/1/messages",
          steerUrl: "/conversations/1/steer_current_turn",
        },
        selectedMode: "steer_current_turn",
      }),
    ).toEqual({
      formAction: "/conversations/1/steer_current_turn",
      resolvedMode: "steer_current_turn",
      runningInputPolicyOverride: null,
    })
  })

  test("falls back to queue when steer mode is selected but unavailable", () => {
    expect(
      deriveComposerFormState({
        railState: {
          running: true,
          queueAvailable: true,
          steerAvailable: false,
          createUrl: "/conversations/1/messages",
          steerUrl: "/conversations/1/steer_current_turn",
        },
        selectedMode: "steer_current_turn",
      }),
    ).toEqual({
      formAction: "/conversations/1/messages",
      resolvedMode: "queue",
      runningInputPolicyOverride: "queue",
    })
  })
})

describe("deriveComposerPreviewText", () => {
  test("prefers the live draft and falls back to the queued candidate preview", () => {
    expect(deriveComposerPreviewText({ draft: "  next draft  ", queuedPreview: "queued follow up" })).toEqual({
      content: "next draft",
      source: "draft",
    })

    expect(deriveComposerPreviewText({ draft: "   ", queuedPreview: "queued follow up" })).toEqual({
      content: "queued follow up",
      source: "queued_turn",
    })
  })
})
