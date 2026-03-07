function readBoolean(value) {
  return value === true || String(value || "") === "true"
}

export function normalizeComposerRailState(rawState) {
  const state = rawState && typeof rawState === "object" ? rawState : {}

  return {
    running: readBoolean(state.running),
    queueAvailable: readBoolean(state.queueAvailable ?? state.queue_available),
    steerAvailable: readBoolean(state.steerAvailable ?? state.steer_available),
    createUrl: String(state.createUrl || state.create_url || ""),
    steerReason: String(state.steerReason || state.steer_reason || ""),
    queuedCount: Number.parseInt(String(state.queuedCount ?? state.queued_count ?? "0"), 10) || 0,
  }
}

export function deriveComposerFormState({ railState }) {
  const normalized = normalizeComposerRailState(railState)

  if (normalized.queueAvailable) {
    return {
      formAction: normalized.createUrl,
      resolvedMode: "queue",
      runningInputPolicyOverride: "queue",
    }
  }

  return {
    formAction: normalized.createUrl,
    resolvedMode: "new_turn",
    runningInputPolicyOverride: null,
  }
}

export function prependQueuedContentToDraft({ queuedContent, draft }) {
  const queuedText = String(queuedContent || "").trim()
  const draftText = String(draft || "").trim()

  if (!queuedText) return draftText
  if (!draftText) return queuedText

  return `${queuedText}\n${draftText}`
}
