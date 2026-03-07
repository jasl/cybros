import { describe, expect, test } from "bun:test"
import { deriveComposerFormState, prependQueuedContentToDraft } from "../../app/javascript/lib/conversation_composer_state"

describe("deriveComposerFormState", () => {
  test("forces queue mode while a run is active", () => {
    expect(
      deriveComposerFormState({
        railState: {
          running: true,
          queueAvailable: true,
          createUrl: "/conversations/1/messages",
        },
      }),
    ).toEqual({
      formAction: "/conversations/1/messages",
      resolvedMode: "queue",
      runningInputPolicyOverride: "queue",
    })
  })

  test("uses a fresh turn when no run is active", () => {
    expect(
      deriveComposerFormState({
        railState: {
          running: false,
          queueAvailable: false,
          createUrl: "/conversations/1/messages",
        },
      }),
    ).toEqual({
      formAction: "/conversations/1/messages",
      resolvedMode: "new_turn",
      runningInputPolicyOverride: null,
    })
  })
})

describe("prependQueuedContentToDraft", () => {
  test("puts the queued content ahead of an existing draft with a blank line separator", () => {
    expect(prependQueuedContentToDraft({ queuedContent: "queued follow up", draft: "" })).toBe("queued follow up")
    expect(prependQueuedContentToDraft({ queuedContent: "queued follow up", draft: "existing draft" })).toBe(
      "queued follow up\nexisting draft",
    )
  })
})
