import path from "node:path"
import { test, expect } from "@playwright/test"
import {
  activateProgrammableAgentRuntime,
  conversationIdFromUrl,
  createHighPriorityMockProvider,
  openNewConversation,
  programmableConversationState,
  railsJson,
  seedProgrammableAgent,
  signIn,
  selectConversationRuntimeOption,
  waitForTailAgentToFinish,
} from "./helpers"

test.describe("Programmable agent conversation attachments", () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page)
  })

  test("uploads text and image attachments, renders them in the transcript, and preserves workspace-only behavior on text-only models", async ({ page }) => {
    test.setTimeout(180_000)

    await createHighPriorityMockProvider(page)
    const suffix = Date.now().toString()
    const agent = seedProgrammableAgent(`E2E Attachment Agent ${suffix}`)
    activateProgrammableAgentRuntime(agent.agentId)

    await openNewConversation(page, `Programmable Attachments ${suffix}`, agent.agentName)
    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Vision Mock")

    const attachmentInput = page.locator('input[name="attachments[]"]')
    await attachmentInput.setInputFiles([
      path.join(process.cwd(), "test/fixtures/files/attachment-image.png"),
      path.join(process.cwd(), "test/fixtures/files/attachment-note.txt"),
    ])

    await expect(page.getByTestId("conversation-composer-attachments")).toBeVisible()
    await expect(page.getByTestId("conversation-composer-attachment")).toHaveCount(2)
    await expect(page.getByTestId("conversation-composer-vision-hint")).toContainText("sent to the model")

    await page.getByPlaceholder("Message…").fill("Inspect these attachments")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentToFinish(page)

    const transcriptAttachments = page.locator('[data-role="user-attachments"]').last()
    await expect(transcriptAttachments.locator('[data-role="user-attachment"]')).toHaveCount(2)
    await expect(transcriptAttachments).toContainText("attachment-image.png")
    await expect(transcriptAttachments).toContainText("attachment-note.txt")

    const conversationId = conversationIdFromUrl(page)
    const firstAgentOutput = programmableConversationState(conversationId).latestAgentNode.outputText || ""
    expect(firstAgentOutput).toContain("Attachment 1: attachment-image.png (image/png)")
    expect(firstAgentOutput).toContain("image_url")

    const firstTurnState = conversationAttachmentState(conversationId)
    expect(firstTurnState.latestUserAttachments.map((entry) => entry.filename)).toEqual([
      "attachment-image.png",
      "attachment-note.txt",
    ])
    expect(firstTurnState.latestUserAttachments[0]?.image).toBe(true)
    expect(firstTurnState.latestUserAttachments[0]?.previewPath).toContain("/rails/active_storage/representations/proxy/")
    expect(firstTurnState.latestPreparationTransferModes).toEqual(["rpc_import", "rpc_import"])
    expect(programmableConversationState(conversationId).composerDraft.modelRef).toBe("dev/vision-model")

    await selectConversationRuntimeOption(page, "conversation-composer-model-picker", "Mock model")
    await attachmentInput.setInputFiles(path.join(process.cwd(), "test/fixtures/files/attachment-image.png"))

    await expect(page.getByTestId("conversation-composer-attachments")).toBeVisible()
    await expect(page.getByTestId("conversation-composer-attachment")).toHaveCount(1)
    await expect(page.getByTestId("conversation-composer-vision-hint")).toContainText("does not accept image input")

    await page.getByPlaceholder("Message…").fill("Now use the text-only model")
    await page.getByRole("button", { name: "Send" }).click()

    await waitForTailAgentToFinish(page)

    const latestTranscriptAttachments = page.locator('[data-role="user-attachments"]').last()
    await expect(latestTranscriptAttachments.locator('[data-role="user-attachment"]')).toHaveCount(1)
    await expect(latestTranscriptAttachments).toContainText("attachment-image.png")

    const secondAgentOutput = programmableConversationState(conversationId).latestAgentNode.outputText || ""
    expect(secondAgentOutput).toContain("Attachment 1: attachment-image.png (image/png)")
    expect(secondAgentOutput).not.toContain("image_url")

    const secondTurnState = conversationAttachmentState(conversationId)
    expect(secondTurnState.latestUserAttachments.map((entry) => entry.filename)).toEqual(["attachment-image.png"])
    expect(secondTurnState.latestUserAttachments[0]?.image).toBe(true)
    expect(secondTurnState.latestPreparationTransferModes).toEqual(["rpc_import"])
    expect(programmableConversationState(conversationId).composerDraft.modelRef).toBe("dev/mock-model")
  })
})

function conversationAttachmentState(conversationId: string) {
  return railsJson<{
    latestUserAttachments: Array<{
      filename: string
      image: boolean
      previewPath: string | null
      downloadPath: string | null
    }>
    latestPreparationTransferModes: string[]
  }>(`
    require "json"

    conversation = Conversation.find(${JSON.stringify(conversationId)})
    latest_user =
      conversation.message_page(limit: 50, mode: :full)
        .fetch("messages")
        .reverse
        .find { |message| message.fetch("node_type", "") == Messages::UserMessage.node_type_key }
    latest_draft = conversation.run_drafts.order(created_at: :desc).first
    latest_attachments =
      Array(latest_user.dig("payload", "input", "attachments")).map do |attachment|
        {
          filename: attachment["filename"],
          image: attachment["image"] == true,
          previewPath: attachment["preview_path"],
          downloadPath: attachment["download_path"],
        }
      end
    transfer_modes =
      if latest_draft
        ConversationAttachmentPreparation.where(run_draft: latest_draft).order(:created_at).pluck(:transfer_mode)
      else
        []
      end

    puts JSON.generate({
      latestUserAttachments: latest_attachments,
      latestPreparationTransferModes: transfer_modes,
    })
  `)
}
