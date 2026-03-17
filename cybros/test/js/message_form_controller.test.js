import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import MessageFormController from "../../app/javascript/controllers/message_form_controller"

class FakeFormElement {
  constructor(action, textarea, modelSelect, permissionSelect, composerDraftUpdatedAtInput) {
    this.action = action
    this._textarea = textarea
    this._modelSelect = modelSelect
    this._permissionSelect = permissionSelect
    this._composerDraftUpdatedAtInput = composerDraftUpdatedAtInput
  }

  querySelector(selector) {
    if (selector === "textarea") return this._textarea
    if (selector === 'select[name="model_ref"]') return this._modelSelect
    if (selector === 'select[name="conversation[permission_mode]"]') return this._permissionSelect
    if (selector === 'input[name="composer_draft_updated_at"]') return this._composerDraftUpdatedAtInput
    return null
  }

  requestSubmit() {}
}

class FakeTextAreaElement {
  constructor(value = "") {
    this.value = value
    this.style = {}
    this.scrollHeight = 24
    this.focusCount = 0
  }

  focus() {
    this.focusCount += 1
  }

  setSelectionRange() {}
}

class FakeFileInput {
  constructor(files = []) {
    this.files = files
  }

  get files() {
    return this._files
  }

  set files(files) {
    this._files = Array.from(files)
    this._value = this._files.length > 0 ? "selected" : ""
  }

  get value() {
    return this._value
  }

  set value(nextValue) {
    this._value = nextValue
    if (nextValue === "") {
      this._files = []
    }
  }
}

class FakeSelectElement {
  constructor(value = "") {
    this.value = value
  }
}

class FakeHiddenInput {
  constructor(value = "") {
    this.value = value
  }
}

class FakeFormData {
  constructor(form) {
    this._entries = []
    const content = form?.querySelector?.("textarea")?.value
    if (typeof content === "string") {
      this._entries.push(["content", content])
    }
    const composerDraftUpdatedAt = form?.querySelector?.('input[name="composer_draft_updated_at"]')?.value
    if (typeof composerDraftUpdatedAt === "string" && composerDraftUpdatedAt.length > 0) {
      this._entries.push(["composer_draft_updated_at", composerDraftUpdatedAt])
    }
  }

  *entries() {
    yield* this._entries
  }
}

class FakeDataTransfer {
  constructor() {
    this._files = []
    this.items = {
      add: (file) => {
        this._files.push(file)
      },
    }
  }

  get files() {
    return this._files
  }
}

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalHTMLFormElement = globalThis.HTMLFormElement
const originalFormData = globalThis.FormData
const originalDataTransfer = globalThis.DataTransfer
const originalFetch = globalThis.fetch

describe("MessageFormController", () => {
  beforeEach(() => {
    globalThis.HTMLFormElement = FakeFormElement
    globalThis.FormData = FakeFormData
    globalThis.DataTransfer = FakeDataTransfer
    globalThis.window = {
      dispatchEvent() {},
      addEventListener() {},
      removeEventListener() {},
      setTimeout,
      clearTimeout,
    }
    globalThis.document = {
      querySelector() {
        return { getAttribute: () => "csrf-token" }
      },
    }
  })

  afterEach(() => {
    globalThis.window = originalWindow
    globalThis.document = originalDocument
    globalThis.HTMLFormElement = originalHTMLFormElement
    globalThis.FormData = originalFormData
    globalThis.DataTransfer = originalDataTransfer
    globalThis.fetch = originalFetch
  })

  test("draftChanged autosaves content and runtime settings to the composer draft endpoint", async () => {
    const requests = []
    const { controller } = buildController({
      textareaValue: "Draft in progress",
      files: [],
      modelValue: "dev/mock-model",
      permissionValue: "conservative",
    })

    globalThis.fetch = async (url, options) => {
      requests.push({ url, options })
      return { ok: true }
    }

    defineValue(controller, "draftSaveDelayMs", 0)

    controller.draftChanged()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(requests).toHaveLength(1)
    expect(requests[0].url).toBe("/conversations/1/composer_draft")
    expect(requests[0].options.method).toBe("PATCH")
    const payload = JSON.parse(requests[0].options.body)
    expect(payload.composer_draft.updated_at).toEqual(expect.any(String))
    expect(payload).toEqual({
      composer_draft: {
        content: "Draft in progress",
        model_ref: "dev/mock-model",
        permission_mode: "conservative",
        updated_at: payload.composer_draft.updated_at,
      },
    })
  })

  test("submit clears a pending composer draft autosave before the send begins", async () => {
    const requests = []
    const { controller, form } = buildController({
      textareaValue: "Send immediately",
      files: [],
      modelValue: "dev/mock-model",
      permissionValue: "conservative",
    })

    globalThis.fetch = async (url, options) => {
      requests.push({ url, options })
      return { ok: true }
    }

    defineValue(controller, "draftSaveDelayMs", 0)

    controller.runtimeSettingChanged()
    controller.submit({
      target: form,
      preventDefault() {},
    })
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(requests).toEqual([])
    expect(controller.submitInFlight).toBe(true)
    expect(controller.submittedDraft).toBe("Send immediately")
  })

  test("submit blocks attachment sends while another request is in flight", () => {
    const { controller, form } = buildController({
      textareaValue: "Follow up",
      files: [fakeFile("next.txt", 12)],
    })
    const prevented = []
    const toasts = []

    globalThis.window.dispatchEvent = (event) => toasts.push(event.detail)
    controller.submitInFlight = true
    controller.submittedDraft = "Original"

    controller.submit({
      target: form,
      preventDefault() {
        prevented.push(true)
      },
    })

    expect(prevented).toEqual([true])
    expect(controller.submitInFlight).toBe(true)
    expect(controller.submittedDraft).toBe("Original")
    expect(toasts).toEqual([{ message: "Wait for the current send to finish before sending attachments.", type: "error" }])
  })

  test("submit queues a text-only follow up while an attachment send is still in flight", () => {
    const submittedFile = fakeFile("submitted.txt", 10)
    const { controller, attachmentInput, form, textarea } = buildController({
      textareaValue: "Follow up",
      files: [],
    })
    const prevented = []
    const toasts = []

    globalThis.window.dispatchEvent = (event) => toasts.push(event.detail)
    selectFiles(controller, attachmentInput, [submittedFile])
    controller.submitInFlight = true
    controller.submittedDraft = "Original"
    controller.submittedAttachmentSelectionToken = controller.attachmentSelectionToken
    textarea.value = "Follow up"

    controller.submit({
      target: form,
      preventDefault() {
        prevented.push(true)
      },
    })

    expect(prevented).toEqual([true])
    expect(controller.pendingSubmissions).toHaveLength(1)
    expect(controller.pendingSubmissions[0]).toEqual({
      action: "/conversations/1/messages",
      entries: [["content", "Follow up"]],
      content: "Follow up",
    })
    expect(textarea.value).toBe("")
    expect(attachmentInput.files).toEqual([submittedFile])
    expect(toasts).toEqual([])
  })

  test("submitEnd preserves attachment selections made after the previous send started", async () => {
    const firstFile = fakeFile("first.txt", 10)
    const nextFile = fakeFile("next.txt", 20)
    const { controller, attachmentInput, textarea } = buildController({
      textareaValue: "Next draft",
      files: [],
    })

    controller.submitInFlight = true
    controller.submittedDraft = "First draft"
    selectFiles(controller, attachmentInput, [firstFile])
    controller.submittedAttachmentSelectionToken = controller.attachmentSelectionToken
    selectFiles(controller, attachmentInput, [nextFile])
    textarea.value = "Next draft"

    await controller.submitEnd({ detail: { success: true } })

    expect(controller.submitInFlight).toBe(false)
    expect(attachmentInput.files).toEqual([nextFile])
    expect(textarea.value).toBe("Next draft")
  })

  test("submitEnd clears attachment selections only when they still match the submitted files", async () => {
    const submittedFile = fakeFile("submitted.txt", 10)
    const { controller, attachmentInput } = buildController({
      textareaValue: "",
      files: [],
    })

    controller.submitInFlight = true
    controller.submittedDraft = ""
    selectFiles(controller, attachmentInput, [submittedFile])
    controller.submittedAttachmentSelectionToken = controller.attachmentSelectionToken

    await controller.submitEnd({ detail: { success: true } })

    expect(controller.submitInFlight).toBe(false)
    expect(attachmentInput.files).toEqual([])
  })

  test("submitEnd preserves same-file reselections made after the previous send started", async () => {
    const submittedFile = fakeFile("submitted.txt", 10)
    const { controller, attachmentInput } = buildController({
      textareaValue: "",
      files: [],
    })

    controller.submitInFlight = true
    controller.submittedDraft = ""
    selectFiles(controller, attachmentInput, [submittedFile])
    controller.submittedAttachmentSelectionToken = controller.attachmentSelectionToken
    controller.prepareAttachmentSelection({ currentTarget: attachmentInput })
    expect(attachmentInput.files).toEqual([])
    selectFiles(controller, attachmentInput, [fakeFile("submitted.txt", 10)])

    await controller.submitEnd({ detail: { success: true } })

    expect(controller.submitInFlight).toBe(false)
    expect(attachmentInput.files).toEqual([fakeFile("submitted.txt", 10)])
  })

  test("submitEnd restores the original attachment selection when an in-flight send fails after reselection started", async () => {
    const submittedFile = fakeFile("submitted.txt", 10)
    const { controller, attachmentInput } = buildController({
      textareaValue: "",
      files: [],
    })

    controller.submitInFlight = true
    controller.submittedDraft = "Original"
    selectFiles(controller, attachmentInput, [submittedFile])
    controller.submittedAttachmentSelectionToken = controller.attachmentSelectionToken
    controller.prepareAttachmentSelection({ currentTarget: attachmentInput })
    expect(attachmentInput.files).toEqual([])

    await controller.submitEnd({ detail: { success: false } })

    expect(controller.submitInFlight).toBe(false)
    expect(attachmentInput.files).toEqual([submittedFile])
  })

  test("prepareAttachmentSelection keeps the original files when DataTransfer is unavailable", () => {
    const submittedFile = fakeFile("submitted.txt", 10)
    const { controller, attachmentInput } = buildController({
      textareaValue: "",
      files: [],
    })

    globalThis.DataTransfer = undefined
    controller.submitInFlight = true
    selectFiles(controller, attachmentInput, [submittedFile])

    controller.prepareAttachmentSelection({ currentTarget: attachmentInput })

    expect(attachmentInput.files).toEqual([submittedFile])
  })
})

function buildController({ textareaValue, files, modelValue = "openai/gpt-5.4", permissionValue = "default" }) {
  const textarea = new FakeTextAreaElement(textareaValue)
  const attachmentInput = new FakeFileInput(files)
  const modelSelect = new FakeSelectElement(modelValue)
  const permissionSelect = new FakeSelectElement(permissionValue)
  const composerDraftUpdatedAtInput = new FakeHiddenInput("")
  const form = new FakeFormElement("/conversations/1/messages", textarea, modelSelect, permissionSelect, composerDraftUpdatedAtInput)
  const controller =
    new MessageFormController({
      application: {},
      scope: {
        element: form,
        identifier: "message-form",
        targets: {},
        outlets: {},
        classes: {},
        data: {},
      },
    })

  defineValue(controller, "defaultAction", form.action)
  defineValue(controller, "queueExpanded", false)
  defineValue(controller, "submitInFlight", false)
  defineValue(controller, "submittedDraft", null)
  defineValue(controller, "attachmentSelectionToken", 0)
  defineValue(controller, "submittedAttachmentSelectionToken", null)
  defineValue(controller, "pendingSubmissions", [])
  defineValue(controller, "hasTextareaTarget", true)
  defineValue(controller, "textareaTarget", textarea)
  defineValue(controller, "hasAttachmentInputTarget", true)
  defineValue(controller, "attachmentInputTarget", attachmentInput)
  defineValue(controller, "hasComposerDraftUpdatedAtInputTarget", true)
  defineValue(controller, "composerDraftUpdatedAtInputTarget", composerDraftUpdatedAtInput)
  defineValue(controller, "hasStatusRailTarget", false)
  defineValue(controller, "hasEditNodeIdInputTarget", false)
  defineValue(controller, "hasEditModeTarget", false)
  defineValue(controller, "hasRunningInputPolicyInputTarget", false)
  defineValue(controller, "hasQueueAlertExpandedTarget", false)
  defineValue(controller, "hasQueueToggleButtonTarget", false)
  defineValue(controller, "hasQueueToggleIconTarget", false)
  defineValue(controller, "hasComposerDraftUrlValue", true)
  defineValue(controller, "composerDraftUrlValue", "/conversations/1/composer_draft")
  defineValue(controller, "draftSaveDelayMs", 250)

  return { controller, textarea, attachmentInput, form, modelSelect, permissionSelect, composerDraftUpdatedAtInput }
}

function fakeFile(name, size) {
  return {
    name,
    size,
    type: "text/plain",
    lastModified: 1234,
  }
}

function selectFiles(controller, attachmentInput, files) {
  attachmentInput.files = files
  controller.attachmentInputChanged()
}

function defineValue(target, key, value) {
  Object.defineProperty(target, key, {
    value,
    writable: true,
    configurable: true,
  })
}
