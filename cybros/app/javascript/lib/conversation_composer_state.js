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
    steerUrl: String(state.steerUrl || state.steer_url || ""),
    steerReason: String(state.steerReason || state.steer_reason || ""),
    queuedCount: Number.parseInt(String(state.queuedCount ?? state.queued_count ?? "0"), 10) || 0,
    candidatePreview: String(state.candidatePreview || state.candidate_preview || "").trim(),
  }
}

export function deriveComposerFormState({ railState, selectedMode }) {
  const normalized = normalizeComposerRailState(railState)
  const requestedMode = String(selectedMode || "").trim()

  if (normalized.running && requestedMode === "steer_current_turn" && normalized.steerAvailable) {
    return {
      formAction: normalized.steerUrl || normalized.createUrl,
      resolvedMode: "steer_current_turn",
      runningInputPolicyOverride: null,
    }
  }

  if (normalized.running && normalized.queueAvailable) {
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

export function deriveComposerPreviewText({ draft, queuedPreview }) {
  const draftText = String(draft || "").trim()
  if (draftText) {
    return { content: draftText, source: "draft" }
  }

  const queuedText = String(queuedPreview || "").trim()
  if (queuedText) {
    return { content: queuedText, source: "queued_turn" }
  }

  return { content: "", source: null }
}
