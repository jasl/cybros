function actionAvailable(policy, key) {
  const actions = policy?.actions
  const entry = actions && typeof actions === "object" ? actions[key] : null
  return entry?.available === true
}

export function deriveConversationControlsState(bubbles, { ignoredRetryNodeId = null } = {}) {
  const entries = Array.isArray(bubbles) ? bubbles : []

  let stopBubble = null
  let retryBubble = null

  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const bubble = entries[index]
    if (!stopBubble && actionAvailable(bubble?.actionPolicy, "stop")) {
      stopBubble = bubble
    }
    if (!retryBubble && bubble?.isTail === true && actionAvailable(bubble?.actionPolicy, "retry")) {
      retryBubble = bubble
    }
  }

  return {
    activeNodeId: stopBubble?.nodeId || null,
    showStop: stopBubble !== null,
    lastErroredNodeId: retryBubble?.nodeId || null,
    showRetry: retryBubble !== null && retryBubble?.nodeId !== ignoredRetryNodeId,
  }
}
