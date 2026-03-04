import { type Page, expect } from "@playwright/test"
import { randomUUID } from "node:crypto"

export async function signIn(page: Page, email = "admin@example.com", password = "Passw0rd") {
  await page.goto("/session/new")
  await page.getByLabel("Email").fill(email)
  await page.getByLabel("Password").fill(password)
  await page.getByRole("button", { name: "Sign in" }).click()
  await page.waitForURL("**/dashboard")
}

export async function createHighPriorityMockProvider(page: Page) {
  await page.goto("/dashboard")
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content")
  if (!csrf) throw new Error("missing csrf token")

  const providerName = `e2e-mock-${randomUUID()}`
  const mockBaseUrl = new URL("/mock_llm/v1", page.url()).toString()

  const res = await page.request.post("/system/settings/llm_providers", {
    headers: { "X-CSRF-Token": csrf },
    form: {
      "llm_provider[name]": providerName,
      "llm_provider[base_url]": mockBaseUrl,
      "llm_provider[api_format]": "openai",
      "llm_provider[priority]": "999",
      "llm_provider[headers_json]": "{}",
      "llm_provider[model_allowlist_text]": "gpt-4o-mini\nmock-model",
    },
  })

  expect(res.ok()).toBe(true)
  await page.goto("/system/settings/llm_providers")
  await expect(page.getByText(providerName, { exact: true })).toBeVisible()
}
