# LLM Catalog Default Model Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refresh the LLM catalog to the approved provider/model lineup, remove compatibility-oriented selection behavior, and add a single site-wide default `model_ref` that overrides the catalog default for new conversations and agent runs without `prefer`.

**Architecture:** Move default model selection from provider-local `default_model` fields to a single catalog top-level `default_model_ref`, plus an optional site override stored in `Account.instance.settings["llm"]["default_model_ref"]`. Simplify runtime resolution so it never auto-switches providers, persists the resolved default model into new conversation metadata, and fails loudly when the selected model becomes unusable.

**Tech Stack:** Rails 8.2, Ruby 4.0, ActiveRecord JSONB settings, AgentCore DAG Runtime, Minitest, existing YAML catalog loader in `lib/cybros/llm/catalog.rb`.

---

### Task 1: Replace catalog defaults with a single top-level default

**Files:**
- Modify: `config/llm/providers.yml`
- Modify: `lib/cybros/llm/catalog.rb`
- Test: `test/lib/cybros/llm/catalog_test.rb`

**Step 1: Write the failing test**

Add assertions that:
- `Cybros::LLM::Catalog.effective.fetch("default_model_ref")`-equivalent behavior exists via the catalog API
- provider specs no longer expose `default_model`
- the new provider keys/models exist:
  - `openai/gpt-5.3-instant`
  - `openai/gpt-5.4`
  - `codex_subscription/gpt-5.3-codex`
  - `codex_subscription/gpt-5.4`
  - `codex_subscription/gpt-5.4-extra-high`
  - `openrouter/openai-gpt-5.4-pro`
  - `dev/mock-model`

Example assertion shape:

```ruby
cat = Cybros::LLM::Catalog.effective
assert_equal "openai/gpt-5.4", cat.default_model_ref
refute cat.provider("openai").key?("default_model")
assert_equal "openai/gpt-5.4-pro", cat.model("openrouter", "openai-gpt-5.4-pro").fetch("api_model")
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/llm/catalog_test.rb`

Expected: FAIL because the catalog still uses provider-local `default_model`, old OpenRouter entries, and `local` instead of `dev`.

**Step 3: Write minimal implementation**

Update `config/llm/providers.yml`:
- add top-level `default_model_ref: "openai/gpt-5.4"`
- remove all provider-local `default_model` keys
- replace OpenRouter model list with the approved lineup
- rename mock provider from `local` to `dev`
- reserve `local` by leaving it unused

Update `lib/cybros/llm/catalog.rb`:
- validate top-level `default_model_ref`
- validate that it references an existing `provider_key/model_key`
- stop requiring `providers.*.default_model`
- add `default_model_ref` access on the catalog object if missing today

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/llm/catalog_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add config/llm/providers.yml lib/cybros/llm/catalog.rb test/lib/cybros/llm/catalog_test.rb
git commit -m "refactor: move llm defaults to global model ref"
```

### Task 2: Refresh tokenizer hints and provider metadata

**Files:**
- Modify: `lib/cybros/token_estimation.rb`
- Test: `test/lib/cybros/token_estimation_test.rb`

**Step 1: Write the failing test**

Add assertions that new model families normalize cleanly:

```ruby
assert_equal "gpt-5.4", Cybros::TokenEstimation.canonical_model_hint("openai/gpt-5.4")
assert_equal "gpt-5.3-chat-latest", Cybros::TokenEstimation.canonical_model_hint("gpt-5.3-chat-latest")
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/token_estimation_test.rb`

Expected: FAIL if the new hints are not in the registry.

**Step 3: Write minimal implementation**

Update `lib/cybros/token_estimation.rb`:
- add tiktoken-backed source entries for the new OpenAI/OpenRouter-facing aliases that need explicit registration
- remove any no-longer-used hint entries added only for the old model lineup if they are now dead

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/token_estimation_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/token_estimation.rb test/lib/cybros/token_estimation_test.rb
git commit -m "chore: refresh token estimation hints for new llm catalog"
```

### Task 3: Add site-wide default model storage and settings UI

**Files:**
- Modify: `app/controllers/system/settings/llm_providers_controller.rb`
- Modify: `app/views/system/settings/llm_providers/index.html.erb`
- Modify: `config/routes.rb` if a dedicated update route is needed
- Modify: `app/models/account.rb` if helper methods improve clarity
- Test: `test/integration/llm_providers_test.rb`

**Step 1: Write the failing test**

Add integration coverage for:
- saving a site-wide default model
- clearing it back to catalog default
- rejecting values that are not currently usable

Example shape:

```ruby
post system_settings_default_llm_model_path, params: { default_model_ref: "openai/gpt-5.4" }
assert_redirected_to system_settings_llm_providers_path
assert_equal "openai/gpt-5.4", Account.instance.settings.dig("llm", "default_model_ref")
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/llm_providers_test.rb`

Expected: FAIL because no site-default endpoint or form exists yet.

**Step 3: Write minimal implementation**

Add controller logic that:
- builds the same usable-model list used by the composer
- accepts either blank or a currently usable `model_ref`
- stores the override in `Account.instance.settings["llm"]["default_model_ref"]`
- clears the override when blank is submitted

Add UI card at the top of the providers index page:
- selector for current usable models
- blank option labeled `Use catalog default`
- read-only text showing the effective source and effective `model_ref`
- warning when a stored override exists but is not in the catalog anymore

Prefer a small helper/private method instead of duplicating usability filtering logic inline.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/llm_providers_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/controllers/system/settings/llm_providers_controller.rb app/views/system/settings/llm_providers/index.html.erb app/models/account.rb config/routes.rb test/integration/llm_providers_test.rb
git commit -m "feat: add site-wide default llm model setting"
```

### Task 4: Simplify resolver precedence and remove compatibility behavior

**Files:**
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Test: `test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb`
- Test: `test/lib/cybros/agent_runtime_resolver_model_ref_test.rb`
- Test: `test/models/conversation_llm_resolution_warning_test.rb`

**Step 1: Write the failing test**

Add resolver coverage for:
- explicit conversation/node `model_ref` wins
- agent `prefer` wins over site default
- site default wins over catalog top-level default
- invalid site default ref falls back to catalog top-level default
- existing-but-unusable site default hard errors
- no "first provider" fallback exists anymore

Example shape:

```ruby
Account.instance.update!(settings: { "llm" => { "default_model_ref" => "openai/gpt-5.4" } })
runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
assert_equal "gpt-5.4", runtime.model
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/agent_runtime_resolver_model_ref_test.rb test/models/conversation_llm_resolution_warning_test.rb`

Expected: FAIL because the resolver still uses provider-local defaults, provider-key aliases, or first-provider fallback logic.

**Step 3: Write minimal implementation**

Update `lib/cybros/agent_runtime_resolver.rb`:
- remove provider-key alias normalization
- remove legacy `openrouter` compatibility logic
- resolve defaults from:
  - explicit node/conversation `model_ref`
  - agent `prefer`
  - site override
  - catalog top-level `default_model_ref`
- if the site override is missing from the catalog, ignore it and use the catalog default
- if the site override exists but is unusable, raise a validation error
- if the catalog default is unusable, raise a validation error
- do not pick "the first usable provider" under any circumstance

Keep provider-call failures as hard errors.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/agent_runtime_resolver_model_ref_test.rb test/models/conversation_llm_resolution_warning_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/agent_runtime_resolver.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/agent_runtime_resolver_model_ref_test.rb test/models/conversation_llm_resolution_warning_test.rb
git commit -m "refactor: make llm selection explicit and non-fallback"
```

### Task 5: Persist the resolved default model into new conversations

**Files:**
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/models/conversation.rb` only if creation helpers need shared logic
- Modify: `app/views/conversations/show.html.erb` only if UI text changes
- Test: `test/integration/conversations_test.rb`
- Test: `test/integration/model_picker_credential_gating_test.rb`

**Step 1: Write the failing test**

Add integration coverage for:
- new conversation creation persists the resolved default `model_ref`
- composer initially selects that exact stored `model_ref`
- agent `prefer` beats the site-wide default during conversation creation

Example shape:

```ruby
post conversations_path, params: { conversation: { title: "New convo" } }
conversation = Conversation.order(:created_at).last
assert_equal "openai/gpt-5.4", conversation.metadata.dig("llm", "model_ref")
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/model_picker_credential_gating_test.rb`

Expected: FAIL because create currently does not persist a resolved default model.

**Step 3: Write minimal implementation**

Update the conversation creation path so it:
- resolves the initial `model_ref` once at creation time
- writes that `model_ref` into conversation metadata
- reuses the same resolution semantics approved in the design

The composer should keep using stored conversation metadata as the selected value.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/model_picker_credential_gating_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/controllers/conversations_controller.rb app/models/conversation.rb app/views/conversations/show.html.erb test/integration/conversations_test.rb test/integration/model_picker_credential_gating_test.rb
git commit -m "feat: persist resolved default model on conversation creation"
```

### Task 6: Remove compatibility code and dead migration paths

**Files:**
- Delete or modify: `db/migrate/20260306000002_rename_openrouter_provider_key_to_openrouter.rb`
- Modify: `lib/cybros/llm/usage_stats.rb`
- Modify: `test/lib/cybros/llm/usage_stats_test.rb`
- Modify: `test/integration/conversations_test.rb`

**Step 1: Write the failing test**

Remove or rewrite tests that currently assert legacy normalization behavior, and add tests that only assert the finalized keys:

```ruby
assert_equal "openrouter", global.first.fetch("provider_key")
refute_includes global.map { |r| r.fetch("provider_key") }, "openrouter"
```

The main "red" here is deleting stale compatibility assertions and keeping only the final desired behavior.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/llm/usage_stats_test.rb test/integration/conversations_test.rb`

Expected: FAIL if legacy normalization logic is still coupled to the tests.

**Step 3: Write minimal implementation**

- remove usage-stat normalization of legacy provider/model refs
- remove the legacy OpenRouter rename migration if the work is not yet committed upstream
- remove legacy conversation tests that assert automatic normalization of stale refs
- leave the system in a clean "current data only" state

If schema cleanup is needed, regenerate with a clean reset rather than preserving old rows.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/llm/usage_stats_test.rb test/integration/conversations_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/llm/usage_stats.rb test/lib/cybros/llm/usage_stats_test.rb test/integration/conversations_test.rb
git rm db/migrate/20260306000002_rename_openrouter_provider_key_to_openrouter.rb
git commit -m "refactor: drop llm compatibility paths"
```

### Task 7: Refresh seeds, docs, and verification

**Files:**
- Modify: `db/seeds.rb`
- Modify: `docs/plans/2026-03-06-llm-provider-v2-codex-openrouter-plan.md`
- Modify: `docs/product/roadmap.md`
- Modify: any other touched docs that mention `openrouter`, `local/mock-model`, or provider-local defaults

**Step 1: Write the failing test**

If there is no direct test for seeds/docs behavior, write the smallest regression that locks the current expected seed record keys, or rely on the CI `db:seed:replant` stage as the verification target.

Example minimal regression:

```ruby
ENV["OPENROUTER_API_KEY"] = "sk-test"
load Rails.root.join("db/seeds.rb")
assert LLMProviderCredential.find_by(provider_key: "openrouter")
```

**Step 2: Run test to verify it fails**

Run either:
- `bin/rails test <seed regression test path>`
- or `env RAILS_ENV=test bin/rails db:seed:replant`

Expected: FAIL if seeds still use old keys.

**Step 3: Write minimal implementation**

- ensure seeds create `openrouter` rows, not `openrouter`
- update docs to describe:
  - top-level `default_model_ref`
  - site-wide default model override
  - `dev` provider name
  - no compatibility / reset expectation

**Step 4: Run test to verify it passes**

Run:
- `env RAILS_ENV=test bin/rails db:seed:replant`
- then the full CI

Expected: PASS

**Step 5: Commit**

```bash
git add db/seeds.rb docs/plans/2026-03-06-llm-provider-v2-codex-openrouter-plan.md docs/product/roadmap.md
git commit -m "docs: update llm catalog defaults and provider lineup"
```

### Task 8: Final verification

**Files:**
- No code changes expected

**Step 1: Run focused regression suite**

Run:

```bash
bin/rails test \
  test/lib/cybros/llm/catalog_test.rb \
  test/lib/cybros/token_estimation_test.rb \
  test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb \
  test/lib/cybros/agent_runtime_resolver_model_ref_test.rb \
  test/integration/llm_providers_test.rb \
  test/integration/conversations_test.rb \
  test/integration/model_picker_credential_gating_test.rb \
  test/lib/cybros/llm/usage_stats_test.rb
```

Expected: PASS

**Step 2: Run full CI**

Run:

```bash
bin/ci
```

Expected: PASS, including `db:seed:replant`

**Step 3: Reset local database if stale data interferes**

Because compatibility is intentionally removed, if local stale data causes noise during manual verification, reset explicitly:

```bash
bin/rails db:drop db:create db:schema:load db:seed
```

Expected: clean local state using only the finalized provider/model keys

**Step 4: Manual verification**

Verify in the browser:
- LLM settings page shows the new default-model selector
- a new conversation gets the expected initial selected model
- changing the site-wide default affects only newly created conversations
- `openrouter` and `dev` appear with finalized names

**Step 5: Commit**

```bash
git status
git add -A
git commit -m "feat: refresh llm catalog defaults and site model selection"
```
