import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static values = {
    conversationId: String,
  }

  static targets = ["agentBubble"]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ConversationChannel", conversation_id: this.conversationIdValue },
      {
        received: (data) => this.#received(data),
      },
    )
  }

  disconnect() {
    if (this.subscription) consumer.subscriptions.remove(this.subscription)
    this.subscription = null
  }

  #received(data) {
    if (!data || data.type !== "node_events") return

    const agentBubble = this.#ensureAgentBubble()
    if (!agentBubble) return

    const events = Array.isArray(data.events) ? data.events : []
    for (const event of events) {
      if (!event) continue

      if (event.kind === "output_delta") {
        const delta = String(event.text || "")
        if (delta) agentBubble.textContent += delta
      } else if (event.kind === "output_compacted") {
        const text = String(event.text || "")
        if (text) agentBubble.textContent = text
      }
    }
  }

  #ensureAgentBubble() {
    if (this.hasAgentBubbleTarget) return this.agentBubbleTarget

    const el = this.element.querySelector("[data-conversation-stream-target='agentBubble']")
    if (el) return el

    return null
  }
}

