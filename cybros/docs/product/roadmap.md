# Implementation Roadmap

## Overview

Four phases, each building on the last. Each phase has concrete acceptance criteria.

```
Phase 0 ── Application Shell ──── "Human talks to a static agent"
Phase 1 ── Programmable Agents ── "Agent runs code and modifies itself"
Phase 2 ── Demo Agents ────────── "Prove the architecture works"
Phase 3 ── Observability ──────── "Understand and improve agents"
```

## Design Strategy

**Cybros is the control plane**: Conduits API (territories, facilities, directives) lives in Cybros. Nexus polls Cybros directly. Mothership is a lightweight prototype/testbed — when protocol or data format changes are needed, prototype in Mothership first (smaller codebase, faster iteration), verify with Nexus, then port the proven design into Cybros.

**Agent programs from day one**: Even Phase 0 uses the agent program file structure (read locally). This ensures the architecture doesn't need to be retrofitted later.

**TavernKit streaming pattern**: Dual-channel architecture adopted wholesale — ActionCable for ephemeral events (typing, stream chunks), Turbo Streams for persistent DOM updates (message creation).

**Gradual AgentCore externalization**: Phase 0 wraps existing AgentCore with data-driven `PromptConfig`. Phase 1 adds hooks that can override the config. No big-bang rewrite.

**Breaking changes are welcome**: The codebase can be destructively modified to achieve the correct design. No backward compatibility burden.

---

## Phase 0: Application Shell

**Goal**: A human can open a browser, create a conversation, and chat with a static agent that streams responses and uses tools.

### Models & Auth

Based on Fizzy's patterns with Discourse-inspired settings:

- **Account**: Phase 0 uses a **single default account** (no URL multi-tenancy). Holds global configuration as JSONB `settings` column (LLM defaults, feature flags). Future phases may add real tenancy.
- **Identity**: Global user identity (**email + `password_digest`**). Single identity created via first-run setup wizard.
- **User**: Phase 0 user record for the identity. Belongs to Identity. A `role` field may exist, but Phase 0 assumes a single "owner" user.
- **Session**: Cookie-based (signed, HTTP-only, SameSite: lax). Modeled after Fizzy's session pattern.
- **Current**: `ActiveSupport::CurrentAttributes` — `Current.user`, `Current.identity`, `Current.account`, `Current.session`.
- **LlmProvider**: API endpoint configuration. Fields: `name`, `base_url`, `api_key` (encrypted), `api_format` (default: "openai"), `headers` (JSONB), `model_allowlist` (string array, required — provider only serves models explicitly listed), `priority` (integer, default: 0 — higher wins when multiple providers serve the same model). Modeled after vibe_tavern's LlmProvider, simplified (no LlmModel/LlmPreset tiers). UI includes a "Fetch Models" button that queries the provider's `/v1/models` endpoint to help populate the allowlist (not all providers support this).
- **Conversation**: Existing model, wired to `DAG::Graph`. Add `belongs_to :agent_program`. Add controller CRUD. Supports soft-delete (archive) and hard-delete.
- **ConversationRun**: State machine (queued → running → succeeded/failed/canceled) tracking each agent execution. Modeled after TavernKit's pattern.
- **AgentProgram**: Points to a local directory containing agent program files (Phase 0) or a Nexus facility (Phase 1). Fields: `name`, `description`, `profile_source`, `local_path`, `args` (JSONB), `active_persona`.

Development: `db/seeds.rb` creates default Account, Identity, User, LlmProvider (from .env), and bundled AgentPrograms.

### LLM Provider Configuration

Phase 0 supports three provider types:

| Provider | Configuration | Notes |
|----------|--------------|-------|
| OpenRouter | API key in .env (`OPENROUTER_API_KEY`) | Access to many models via single key |
| Local (LM Studio / vLLM) | Base URL (e.g., `http://localhost:1234/v1`) | No API key needed |
| Mock LLM | Built-in dev endpoint (`/mock_llm/v1/`) | Ported from vibe_tavern, for testing |

Codex OAuth: Deferred to Phase 1 (requires PKCE OAuth flow implementation).

The .env file provides a backdoor for initial secrets (API keys) to simplify setup and enable integration testing:

```bash
OPENROUTER_API_KEY=sk-or-...
LLM_PROVIDER_NAME=openrouter
LLM_PROVIDER_BASE_URL=https://openrouter.ai/api/v1
```

Seeds read these and create the corresponding LlmProvider record.

### Chat UI

Adopt TavernKit's proven streaming architecture:

- **Conversation list**: Sidebar with conversation titles, ordered by last activity.
- **Message stream**: Messages rendered from DAG transcript projection. Markdown rendering.
- **Input**: Text input with send button. Keyboard shortcuts.
- **Streaming**: ActionCable `ConversationChannel` for ephemeral events:
  - `typing_start` / `typing_stop`: Show/hide typing indicator
  - `stream_chunk`: Update typing indicator with accumulated content
  - `stream_complete`: Signal that streaming is done
- **Message creation**: Turbo Stream `append` when agent_message node is created atomically (no placeholder messages).
- **Error handling**: ConversationRun failure → show error in UI, allow retry.
- **Stuck detection**: Heartbeat timeout → show warning, allow cancel.

### Agent Execution Pipeline

```
User submits message
  → ConversationsController#create_message
  → Create user_message DAG node
  → Enqueue ConversationRunJob (Solid Queue)
  → Return immediately (optimistic UI via Turbo Stream)

ConversationRunJob:
  → Load agent program (AgentProgramLoader reads files from local directory)
  → Build PromptConfig (AGENT.md + SOUL.md + system.md.liquid + tools + skills)
  → Feed PromptConfig into SystemPromptSectionsBuilder (existing AgentCore, adapted)
  → Assemble context (DAG context_for)
  → broadcast_typing_start
  → Call LLM (streaming via AgentCore executor)
    → Each chunk: broadcast_stream_chunk
  → Tool calls? → Execute in-process → broadcast tool status → Continue loop
  → Create agent_message DAG node
  → broadcast_create (Turbo Stream append)
  → broadcast_typing_stop + stream_complete
```

### Built-in Tools (In-Process)

These tools run inside the Cybros process, no Nexus required:

- `memory_search`, `memory_store`, `memory_forget` (pgvector, existing)
- `skills_list`, `skills_load`, `skills_read_file` (existing)
- `web_search`, `web_fetch` (HTTP calls from Cybros process)

### UI Skeleton

Build the full UI shell in Phase 0, even if some sections are empty:

- **Navigation**: Sidebar with sections: Conversations, Agents, Settings
- **Conversations page**: List + chat view. Support delete and archive (soft-delete).
- **Agents page**: List of available agent programs. Create new agent from bundled profile (UI-driven). Read-only detail view in Phase 0 (full editing in Phase 1).
- **Settings page**: LLM providers CRUD (with "Fetch Models" button), Account settings, User profile
- **Mock LLM**: Development-only controller (ported from vibe_tavern) at `/mock_llm/v1/`

> Note: Several ChatGPT-grade UI/UX details (three-pane responsive shell, strict message ordering under rapid interactions, typing indicator/retry/cancel UX, and improved streaming observability) are intentionally deferred to **Phase 0.5** to keep Phase 0 focused on end-to-end plumbing.

### Bundled Agent Programs

Phase 0 ships only `default-assistant`. The `coder` and `mac-assistant` profiles are added in Phase 1 (they require Nexus).

In `cybros-agent/profiles/default-assistant/`:

```
default-assistant/
├── agent.yml
├── AGENT.md
├── SOUL.md
└── prompts/
    └── system.md.liquid
```

### Acceptance Criteria

- [ ] First-run setup: open browser → create Identity + User → land on conversations page
- [ ] Create conversation: select agent → new conversation appears
- [ ] Send message: type → send → see typing indicator → streaming response appears
- [ ] Multi-turn: conversation history preserved, context passed to LLM correctly
- [ ] Tool calling: agent uses memory_search/store, results visible in conversation
- [ ] Agent behavior: changing AGENT.md or SOUL.md files changes agent behavior on next turn
- [ ] ConversationRun lifecycle: can see run status (running/succeeded/failed), retry on failure
- [ ] LLM Provider management: add/edit/delete providers from Settings UI
- [ ] Mock LLM: tests can run against mock endpoint without real API keys
- [ ] Conversation lifecycle: can archive (soft-delete) and delete conversations
- [ ] Agent creation from UI: create new agent from bundled profile
- [ ] Development: `bin/setup` + `bin/dev` + seeds → working instance with default agent

---

## Phase 0.5: UI + Streaming Hardening

**Goal**: Implement a **complete, product-grade UI skeleton** (ChatGPT-style) and make the **chat page transport** (server-push + connectivity + ordering) robust and componentized, so future product shapes (e.g. Telegram bot) can reuse the same streaming/update semantics.

### Guiding principles

- **One UI shell, many surfaces**: Web UI today; other surfaces (Telegram bot, etc.) later should reuse the same *conversation event stream* and *run state model*.
- **Componentize the hard parts**: message list rendering, streaming bubble, indicator state machine, reconnect/resume logic, and event ordering must be isolated and testable.
- **Server-push by default**: Phase 0.5 should remove “per-connection 0.25s polling” as the primary mechanism. Keep polling only as a low-frequency fallback.

### Milestones (deliverables)

#### 0.5-A0 — Rails layouts & surfaces (landing / agent / settings)

Prepare **three Rails layouts** so each surface has a clean, consistent UI skeleton:

- **`landing` layout** (unauthenticated):
  - Update the current **Home page** to become the product landing page (visual polish + clear CTA).
  - Keep it independent from the authenticated app shell (no 3-pane constraint).
- **`agent` layout** (authenticated chat surface):
  - Used by the chat UI (the “left / center / right” 3-column layout described below).
  - Optimized for conversation flows and inspection/debug context.
- **`settings` layout** (authenticated dashboard surface):
  - Used by **Dashboard**, **`/settings`**, and **`/system/settings`** pages.
  - Optimized for forms, tables, CRUD workflows; can be simpler than the chat surface (no always-on inspector).

#### 0.5-A — Agent layout: App Shell (3-pane, responsive)

Build a **three-pane layout** (ChatGPT-inspired) used by authenticated **agent surfaces** (not the landing page):

- **Left sidebar (collapsible)**:
  - Primary nav: Dashboard / Conversations / Agents / Settings
  - Conversation list (recency grouping + search)
  - Collapsed mode: icons only
- **Main pane**:
  - Route content (dashboard cards, chat, settings forms)
- **Right pane (on-demand)**:
  - Inspector/Context drawer (selected message, run status, provider/model, tool calls, debug)
  - Opens per selection or route; dismissible

**Responsive acceptance**:
- **Mobile**: left sidebar as drawer; right pane as modal/drawer; composer always reachable.
- **Tablet**: left collapsible; right overlays/docks depending on width.
- **Desktop**: full three-pane; optional resize handles.

#### 0.5-B — Pages (Dashboard + `/settings` + `/system/settings`)

Add top-level pages across the layouts (content can be minimal, but layout + routing must be real):

- **Dashboard**:
  - Recent conversations
  - Status cards (provider connectivity, model allowlist health, last run summary)
  - Quick actions
- **`/settings` (Personal settings)**:
  - Profile (email/password change)
  - Sessions (sign out all)
- **`/system/settings` (System settings, in `System` namespace)**:
  - LLM providers (existing CRUD, improved inline validation UX)
  - Agent programs management (existing, plus browsing/search)

#### 0.5-C — Chat transport: server-push + connectivity (reference: tavern_kit/playground)

Solve *all* chat-page communication problems in Phase 0.5 (no partial fixes):

- **Server-push events**:
  - Prefer broadcasting on `DAG::NodeEvent` creation (and/or stream flush) rather than per-connection polling.
  - Define a stable event envelope usable by other surfaces (e.g. Telegram):
    - `conversation_id`, `turn_id` (or run id), `node_id`, `event_id`, `kind`, `text`, `payload`, timestamps.
- **Connectivity**:
  - Reconnect, resume-from-cursor, and dedupe without duplicating text.
  - Explicit “active run node” tracking (do not infer from “latest leaf”).
- **Ordering invariants** (non-negotiable):
  - Rapid sends create distinct user bubbles **in order**.
  - Each user message pairs to the correct assistant bubble.
  - Out-of-order arrival must not reorder UI; reconcile by `(turn_id, node_id, event_id)`.

#### 0.5-D — Chat UX: indicator + error/retry/cancel (state machine)

- **Streaming indicator**:
  - Anchored to the currently streaming assistant bubble.
  - State transitions: idle → streaming → completed / errored / canceled.
- **Error / retry / cancel**:
  - Inline errors on the relevant assistant bubble.
  - Retry generation (new node or rerun semantics, consistent with DAG).
  - Stop/cancel while streaming.
- **Stuck detection**:
  - Heartbeat timeout → show warning + allow cancel/retry.

#### 0.5-E — Observability & debuggability

- **Rate-limited warnings** (no silent stalls).
- Structured logs for: subscribe, reconnect, cursor advance, event counts by kind.
- Dev-only debug overlay for stream state (cursor, node id, run state).

### Edge/extreme test matrix (required)

Add system + integration tests that cover:

- **Rapid sends**: 3–10 messages quickly; assert ordering + pairing.
- **Reconnect**: disconnect/reconnect mid-stream; resume without duplication.
- **Compaction**: deltas compacted mid-stream; UI remains correct.
- **Out-of-order events**: simulate reordering; UI stable by reconciliation keys.
- **Provider/model mismatch**: clear UX when no provider supports preferred models.
- **Invalid provider config**: invalid headers JSON is 422 with inline errors (no 500).
- **Long outputs**: large responses; UI remains responsive and bounded.

### Acceptance Criteria

> Project is early-stage. Until the first external beta, **destructive changes are allowed** and plans may evolve; optimize for correctness and product shape over backward compatibility.

- [ ] **Rails layouts**:
  - [ ] `landing` / `agent` / `settings` layouts exist
  - [ ] **Home** uses `landing`
  - [ ] **Conversations + Agents** use `agent`
  - [ ] **Dashboard + `/settings` + `/system/settings`** use `settings`
- [ ] **App shell (agent layout)**: three-pane layout exists and is used by authenticated agent surfaces
- [ ] **Responsive**:
  - [ ] Mobile: left sidebar is a drawer; right pane is a modal/drawer; composer always reachable
  - [ ] Tablet: left collapsible; right overlays/docks appropriately
  - [ ] Desktop: full three-pane; navigation + inspector usable
- [ ] **Dashboard**: route exists and renders meaningful status cards (can be minimal content)
- [ ] **`/settings`**: profile + session management routes exist (can be minimal content)
- [ ] **`/system/settings`**: system settings live under `System` namespace and are usable (LLM providers + agent programs management; existing CRUD integrated)
- [ ] **Chat transport (server-push)**:
  - [ ] Server-push is the primary streaming mechanism (polling only low-frequency fallback)
  - [ ] Stable event envelope exists and is surface-agnostic (usable by future Telegram bot)
  - [ ] Reconnect/resume-from-cursor works without duplication
  - [ ] Active run node tracking is explicit (no “latest leaf” inference)
- [ ] **Ordering invariants**:
  - [ ] Rapid sends preserve user bubble order
  - [ ] Each user message pairs to the correct assistant response bubble
  - [ ] Out-of-order event arrival does not reorder UI; reconciliation key(s) enforced
- [ ] **Indicator + controls**:
  - [ ] Typing/streaming indicator anchored to the streaming assistant bubble
  - [ ] Inline error presentation, retry, cancel/stop generation, and stuck detection all work end-to-end
- [ ] **Observability**:
  - [ ] Rate-limited warnings/logs prevent silent stalls
  - [ ] Dev-only debug overlay shows stream state (cursor/node/run state)
- [ ] **Tests**: the edge/extreme matrix above is covered by system/integration tests and is stable in CI
- [ ] **Handoff quality gate (required before acceptance)**:
  - [ ] **Smoke tests**: add a system test suite that visits each top-level page (Home, Dashboard, Conversations, Agents, `/settings`, `/system/settings`) and asserts it loads (no routing typos, no ERB syntax/render exceptions)
  - [ ] **Browser verification**: manually verify in a real browser that each page’s layout/styles are correct and that key UI interactions work (navigation, drawer/collapse behavior, forms/CRUD flows, chat composer/send)

---

## Phase 1: Programmable Agents + Nexus Integration

**Goal**: Agents execute code via Nexus, use hooks for dynamic behavior, modify themselves, and coding/macOS tools work.

### Nexus Integration

Port the Conduits control plane from Mothership into Cybros. Nexus polls Cybros directly.

- **Conduits controllers in Cybros**: Port Mothership's Conduits namespace (territories, facilities, directives, policies) into Cybros. Reuse the existing models, services, and API design. Adapt for Cybros's Account model and auth.
- **Conduits API endpoints** (served by Cybros):
  - `POST /conduits/v1/polls` — Nexus claims directives
  - `POST /conduits/v1/territories/enroll` — Register territory
  - `POST /conduits/v1/territories/heartbeat` — Territory presence
  - `POST /conduits/v1/directives/:id/started` — Report execution start
  - `POST /conduits/v1/directives/:id/heartbeat` — Renew lease
  - `POST /conduits/v1/directives/:id/log_chunks` — Upload stdout/stderr
  - `POST /conduits/v1/directives/:id/finished` — Report completion
- **Internal directive creation**: AgentCore tool calls create directives directly in the Cybros database (no HTTP round-trip to an external service).
- **Directive execution flow**:
  1. AgentCore tool call → Cybros creates directive record in DB
  2. Nexus polls Cybros, claims directive
  3. Nexus executes command in facility (host driver)
  4. Nexus reports result to Cybros
  5. ConversationRunJob polls the directive record for completion
- **ActiveJob orchestration**: ConversationRunJob manages directive creation and polls the DB for completion. Uses Solid Queue. Known limitation: polling in the job holds a worker thread for the directive duration. Acceptable for single-user; callback-based approach deferred.
- **Protocol changes**: If the Conduits API needs changes, prototype in Mothership first (verify with Nexus), then port the proven changes into Cybros.

### Hook Execution

- `before_inference` hook: Runs via Nexus directive before each LLM call. Output merged into PromptConfig.
- `on_conversation_start` hook: Runs when a new conversation is created with this agent.
- `after_tool_call` hook: Runs after a tool returns a result (optional).
- **Fallback**: If hook fails, times out (default: 30s), or is absent → proceed with static config only.

### Coding Tools (via Nexus)

Tools for coding agent capabilities, executed as Nexus directives in a project facility:

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents (with optional line range) |
| `write_file` | Create or overwrite a file |
| `edit_file` | Apply targeted edits to a file |
| `bash` | Execute shell command |
| `glob` | Find files matching a pattern |
| `grep` | Search file contents |
| `git_status` | Show git status |
| `git_diff` | Show git diff |
| `git_commit` | Commit changes |
| `git_log` | Show commit history |

### Workspace Management

- Workspace path stored as a persistent fact (KV) on the agent or conversation
- User tells agent "work on /path/to/project" → agent validates → stores as fact
- All coding tools execute relative to this workspace path
- Phase 1: workspace is a Nexus facility; directives execute with `cwd` set to facility mount
- No path restrictions in host driver mode (single user trusts themselves)

### macOS Automation Tools (via Nexus)

Tools for macOS automation, executed as Nexus directives on a macOS territory:

| Tool | Description |
|------|-------------|
| `run_applescript` | Execute an AppleScript string via `osascript` |
| `open_url` | Open a URL in the default browser |
| `take_screenshot` | Capture screen via `screencapture` |
| `run_shortcut` | Execute a macOS Shortcut by name |
| `list_apps` | List installed applications |

### Self-Modification

- Agent self-modification tools: `agent_read_self`, `agent_write_self`, `agent_edit_self`, `agent_commit`, `agent_diff`, `agent_revert`, `agent_log`.
- Git operations via ruby-git gem (in-process for local repos) or Nexus directives (for remote repos).
- Health check after modification: test message → verify response → auto-revert if broken.
- Version history UI: commit log, diffs, one-click revert.

### Custom Tools (Agent-Defined)

- Agent declares custom tools in `tools/*.yml` + `tools/*.rb` (or any executable).
- Tool name maps to files by convention: `fortune` → `tools/fortune.yml` + `tools/fortune.rb`.
- Execution: Cybros creates Nexus directive to run tool script in agent's facility.
- Result returned to AgentCore tool loop.

### Agent Management UI

- Agent list: show available agent programs (bundled + user-created).
- Create agent: from bundled profile, from GitHub URL, or blank.
- Agent detail: config view, version history (git log), health status.
- Create conversation: select which agent to use.

### Codex OAuth (Optional)

- Implement PKCE OAuth flow for OpenAI Codex subscription (reference: OpenClaw's implementation).
- Store OAuth tokens in LlmProvider credentials.
- Token refresh on expiry.

### Bundled Agents (Upgraded)

Upgrade `default-assistant` and add new agents:

- `default-assistant`: Now with Nexus-backed tools (code_execution, web tools).
- `coder`: Coding agent with read_file, write_file, edit_file, bash, glob, grep, git_*.
- `mac-assistant`: macOS automation agent with run_applescript, open_url, take_screenshot.

### Acceptance Criteria

- [ ] Coding agent: can read files, write code, run tests, fix bugs in a project repo via Nexus
- [ ] macOS automation: agent can open apps, run AppleScript, take screenshots
- [ ] Hook execution: before_inference hook runs and modifies agent behavior dynamically
- [ ] Custom tools: agent-defined tool executes in sandbox and returns result
- [ ] Self-modification: ask agent to change itself → change persists → can revert from UI
- [ ] Health check: broken self-modification auto-reverts
- [ ] Agent creation: create new agent from bundled profile, GitHub URL, or blank
- [ ] Directive pipeline: Cybros (Conduits API) ↔ Nexus → result flows end-to-end
- [ ] Workspace: coding agent remembers project path across turns

---

## Phase 2: Demo Agents

**Goal**: Ship diverse agent demos that prove the programmable agent framework handles radically different use cases.

**Implementation note**: Persona definitions, system prompts, tool configurations, and workflow patterns for these agents should be sourced from the `references/` directory where possible (OpenClaw, RisuAI, Pi-mono, Codex, OpenCode, etc.). Use proven, battle-tested prompts and patterns rather than writing from scratch.

### 2a: Multi-Persona Agent

- **Persona router**: `before_inference` hook classifies user intent, selects persona.
- **Each persona**: subdirectory with its own SOUL.md + system.md.liquid + tool allowlist.
- **Switching**:
  - Explicit: user says "switch to coder mode" → agent switches
  - Automatic: hook detects intent shift (coding question → coder persona)
  - Configurable: `router: auto | explicit | hook` in agent.yml
- **Shared state**: Conversation history shared across personas. Persona switch recorded as DAG event.

**Acceptance**:
- [ ] Agent switches persona based on user message content
- [ ] Different personas have visibly different behavior (tone, tools, focus)
- [ ] Explicit switch command works ("switch to writer mode")
- [ ] Persona history visible in conversation

### 2b: Multi-Agent / Swarm

- **Coordinator pattern**: A coordinator agent program uses `subagent_spawn`/`subagent_poll` to orchestrate specialists.
- **Each specialist**: Separate agent program on its own facility.
- **Task routing**: Coordinator decides task breakdown, assigns to specialists, aggregates results.
- **Example**: Research agent spawns `web_researcher` + `summarizer` + `fact_checker`.

**Acceptance**:
- [ ] Coordinator spawns specialist agents for subtasks
- [ ] Specialists execute independently and return results
- [ ] Coordinator aggregates and presents final answer
- [ ] User sees the orchestration happening (which agent is working on what)

### 2c: Roleplay Agent

- **Character card**: SOUL.md defines character personality, background, speech patterns, appearance.
- **Lorebook**: `data/lorebook.yml` contains world-building entries. Cybros scans user messages for keywords and injects matching entries into context.
- **Memory**: Long-term relationship memory via memory tools (pgvector).
- **Character message**: Uses `character_message` DAG node type (already exists).
- **Group chat** (stretch): Multiple character agents in same conversation via subagents.

**Acceptance**:
- [ ] Agent stays in character across multi-turn conversation
- [ ] Lorebook entries surface when relevant keywords appear
- [ ] Agent remembers past interactions (long-term memory)
- [ ] Character personality is defined entirely by agent program files (portable)

### 2d: Game Agent — Astrology Fortune-Telling

- **Knowledge base**: Astrology knowledge in skills/ directory.
- **Custom tools**: `get_zodiac_info`, `calculate_compatibility`, `daily_fortune`.
- **Structured output**: Fortune results as structured data.
- **Rich display** (stretch): First candidate for predefined UI components (fortune cards).

**Acceptance**:
- [ ] Agent provides zodiac-based fortune readings
- [ ] Custom tools execute and return structured results
- [ ] Knowledge base correctly informs agent's responses
- [ ] Agent can be self-modified to add new fortune categories

---

## Phase 3: Observability & Polish

**Goal**: Data-driven agent improvement loop.

### Usage Dashboard

- Conversations: count, duration, messages per conversation
- Token usage: per model, per agent, per conversation
- Cost tracking: estimated cost per agent, per conversation
- Tool usage: call frequency, success rate, average latency

### Agent Performance

- Success rate: conversations completed vs abandoned/errored
- Latency: time-to-first-token, total response time
- Error frequency: tool failures, LLM errors, hook failures
- Version comparison: side-by-side metrics for agent versions

### Context Management

- Context budget visualization: show what fills the prompt window
- Compression effectiveness: tokens saved by compression
- Memory relevance: hit rate for memory_search results

### Prompt Cache Optimization

A key cost driver for agent products (including OpenClaw) is poor prompt cache hit rate — system prompts that change slightly each turn invalidate the cache, causing massive token consumption.

Metrics to track:
- Prompt cache hit rate per provider (Anthropic and OpenAI report this in response headers/usage)
- Cache-eligible tokens vs total prompt tokens
- Cost savings from cache hits vs estimated cost without caching

Optimization techniques:
- Stable prompt prefix: ensure the system prompt sections that don't change (AGENT.md, SOUL.md) are at the beginning and identical across turns
- Separate stable vs dynamic sections: put volatile content (recent messages, hook output) at the end
- Minimize unnecessary prompt variation: avoid injecting timestamps, random IDs, or other per-turn noise into the system prompt
- Track which prompt sections change between turns and why

This requires the prompt assembly pipeline (AgentProgramLoader → PromptConfig → SystemPromptSectionsBuilder) to be **cache-aware** from the start: stable sections first, dynamic sections last, minimize unnecessary variation. Implementation should consider this even in Phase 0, though metrics and active optimization are Phase 3 work.

### Acceptance Criteria

- [ ] Dashboard shows usage stats across agents and conversations
- [ ] Can compare performance between agent versions
- [ ] Token costs visible per conversation and per agent
- [ ] Context budget visible for debugging prompt assembly
- [ ] Prompt cache hit rate visible per provider and per agent

---

## Future Phases (Not Scheduled)

These are tracked for planning purposes but not committed to a timeline:

- **Plugin/Extension system**: Discourse-style plugins for customizing Cybros itself
- **Channel integrations**: Telegram, Discord, Slack, webhook adapters
- **A2UI**: Agent-driven UI rendering (rich components → arbitrary HTML)
- **A2A / ACP**: Agent-to-agent protocol for cross-instance communication
- **Multi-execution environment discovery**: Agent auto-detects machine capabilities
- **Scheduling / Automation**: Cron-based triggers, event-driven agent runs
- **Multi-user / multi-tenancy**: Full Account model, invitation, URL-based routing, role-based access
- **OAuth login**: UserAssociatedAccount for Google, GitHub, etc.
- **Sandbox isolation**: Bubblewrap, container, microVM drivers for Nexus
- **Runtime Facts KV**: Mutable key-value store via internal MCP (no decay, write-back without git)
- **Internal MCP server**: Expose Cybros services (memory, facts, knowledge base) to agent programs
- **Codex OAuth**: PKCE OAuth flow for OpenAI Codex subscription (may move to Phase 1 if needed)
- **Context compression tuning**: Advanced compression strategies
