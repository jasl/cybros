# Cybros

This file provides guidance to AI coding agents working with this repository.

## What is Cybros?

Cybros is an experimental AI Agent platform that models agent conversations as dynamic Directed Acyclic Graphs (DAGs). Instead of treating agent interactions as linear chat logs, Cybros represents every action — user messages, agent responses, tool calls, sub-agent tasks, and context summaries — as typed nodes in a DAG. A workflow engine schedules agent execution based on graph topology, enabling parallel task execution, dependency tracking, conversation branching, and lane compression for context management.

The platform is designed for observability (and future multi-tenancy): the DAG structure makes it possible to visualize, monitor, and audit every step of an agent's reasoning and actions.

## Development Commands

### Setup and Server
```bash
bin/setup              # Initial setup (installs gems, creates DB, loads schema)
bin/dev                # Start development server (runs on port 3000)
```

Development URL: http://localhost:3000

Phase 0 auth is **email + password**. On first run, complete the setup wizard to create the initial user, then sign in.

### Testing
```bash
bin/rails test                           # Run unit tests (fast)
bin/rails test test/path/file_test.rb    # Run single test file
bin/rails test test/path/file_test.rb:42 # Run single test method by line number
bin/rails test:system                    # Run system tests (Capybara + Selenium)
bin/ci                                   # Run full CI suite (style, security, tests)

# For parallel test execution issues, use:
PARALLEL_WORKERS=1 bin/rails test
```

CI pipeline (`bin/ci`) runs:
1. Rubocop (style)
2. Bundler audit (gem security)
3. Brakeman (security scan)
4. Application tests
5. Seed data validation

### Database
```bash
bin/rails db:fixtures:load   # Load fixture data
bin/rails db:migrate          # Run migrations
bin/rails db:reset            # Drop, create, and load schema
```

### Destructive refactors (allowed)

Cybros is experimental and breaking changes are expected. When doing **destructive DB refactors**, it's OK to:

- Edit existing migrations in place (instead of layering compatibility migrations).
- Regenerate schema by resetting the DB (`bin/rails db:reset`).

### Enum / state storage

For readability and debuggability, store enums / states as **strings** in the database:

- Prefer `t.string :status` / `t.string :role` columns.
- Prefer string-backed Rails enums (e.g. `enum :role, ROLES.index_by(&:itself)` or `{ admin: "admin" }`).
- Avoid integer-backed enums for new fields (and migrate old ones to strings when doing destructive refactors).

### Other Utilities
```bash
bin/rails dev:email          # Toggle letter_opener for email preview
bin/jobs                     # Manage Solid Queue jobs
bin/kamal deploy             # Deploy (requires 1Password CLI for secrets)
```

## Technology Stack

- **Backend**: Ruby 4.0.1, Rails 8.2.0.alpha (from main branch)
- **Frontend**: Stimulus + Turbo (Hotwire), Tailwind CSS 4 + DaisyUI 5
- **Database**: PostgreSQL 18 with pgvector extension (via `neighbor` gem)
- **Assets**: Propshaft, cssbundling-rails, jsbundling-rails, Bun
- **Background Jobs**: Solid Queue (database-backed, no Redis)
- **Caching**: Solid Cache (database-backed)
- **WebSocket**: Solid Cable (database-backed)
- **Icons**: Lucide (via @iconify/tailwind4)
- **i18n**: English + Chinese (zh-CN), with fallbacks

## Architecture Overview

### Account (Phase 0)

Phase 0 runs as a **single default Account** and does **not** implement URL path-based multi-tenancy.

- `Account` exists primarily as a **global settings container** (Discourse SiteConfig-style).
- There is **no** `/{external_account_id}/...` route prefix in Phase 0.
- Do **not** assume all app tables have `account_id` in Phase 0.

### Multi-Tenancy (future: URL path-based)

Cybros is designed to support URL path-based multi-tenancy in later phases:
- Each Account (tenant) has a unique `external_account_id` (7+ digits)
- URLs are prefixed: `/{account_id}/conversations/...`
- Middleware extracts the account ID from the URL and sets `Current.account`
- The slug is moved from `PATH_INFO` to `SCRIPT_NAME`, making Rails think it's "mounted" at that path
- Background jobs automatically serialize and restore account context

**Key insight**: This architecture allows multi-tenancy without subdomains or separate databases.

### Authentication & Authorization (Phase 0)

**Email + password authentication**:
- Global `Identity` (email + `password_digest`)
- Cookie `Session` (signed, HTTP-only; SameSite=Lax)

Future phases may add magic links and OAuth.

### DAG-Based Conversation Engine (Core Domain)

The central abstraction of Cybros is the **conversation DAG**. Each conversation is a directed acyclic graph where every interaction becomes a node.

### Public API boundary (important)

When working on DAG-related code (engine, app integration, tests, scripts):

- Prefer **Public API** over touching internal tables/associations directly.
- If the Public API is missing a capability, add/adjust the Public API + tests/doc, then use it (avoid “hacky” direct SQL/`update_columns` from the App domain).

Doc: `docs/dag/public_api.md`

### Validation / Coercion 原则（重要）

当一个入参可能来自**用户输入**（例如 controller params / URL query / JSON payload）：

- **不允许 Ruby 原生 `ArgumentError/TypeError` 漏出**（例如 `Integer(limit)` / `Float(timeout_s)`），应先做安全 coercion/校验，再抛域内 `ValidationError`（或子类）并附带稳定 `code` + safe `details`。
- 避免 silent coercion（例如 `to_i`/`to_f` 会把 `" "` 变成 `0`），推荐用 `Integer(value, exception: false)` / `Float(value, exception: false)`，失败时 raise `DAG::PaginationError` / `AgentCore::MCP::ServerConfigError` 等。

当入参来自**开发者/程序内数据**（例如常量、内部 struct、模型字段、代码路径不应出现的值）：

- 倾向 **fail-fast**：不要“自动修复/宽松转换”；允许原生异常/内部错误尽早暴露，帮助尽快定位 bug。

### DAG API safety tiers（very important）

When building App features (controllers/views/services), treat the DAG engine as **Lane-first**:

- **App-safe (user sync requests)**: only use `DAG::Lane` / `DAG::Turn` primitives (keyset paging + bounded limits), plus bounded mutations (`fork/merge/archive`, node commands).
- **Dangerous/internal (admin/job/diagnostics only)**: graph-wide closure/export/visualization/audit/repair. Do not call these from user-facing request paths:
  - `DAG::Graph#context_closure_for*`
  - `DAG::Graph#transcript_closure_for*`
  - `DAG::Graph#to_mermaid(...)`
  - `DAG::GraphAudit.scan(...)` on large graphs

If you need a capability for the App, extend the **Public API** + add tests/docs, instead of reaching into internal tables/SQL.

#### Node Types
- `system_message` — System prompt / global rules (not executable)
- `developer_message` — Developer prompt / product constraints (not executable)
- `user_message` — User's input to the agent
- `agent_message` — Agent's response to the user
- `character_message` — Roleplay / multi-actor message (executable)
- `task` — An executable action (tool call, MCP request, skill invocation)
- `summary` — Compressed representation of a lane (for context economy)

#### Node States
- `pending` — Created but not yet processed
- `awaiting_approval` — Waiting for human approval (pre-execution gate; not claimable)
- `running` — Currently being executed
- `finished` — Completed successfully
- `errored` — Failed (retryable for agent nodes)
- `rejected` — User declined to authorize the operation
- `skipped` — User skipped the node (e.g. the task is unneeded)
- `stopped` — User stopped generation/execution (terminal)

#### Edge Types
- `sequence` — Temporal ordering (A happens before B)
- `dependency` — B requires A's output to execute
- `branch` — User-initiated fork from an existing node

#### Key DAG Properties
1. **Dynamic**: Nodes are added as the conversation progresses; no predefined end state
2. **Valid at all times**: Every leaf node must be an `agent_message`/`character_message` or be in a `pending`/`awaiting_approval`/`running` state
3. **Parallel execution**: Independent sibling nodes (same dependencies) execute concurrently
4. **Lane compression**: Completed branches can be replaced with a `summary` node to save context
5. **Non-destructive compression**: Original nodes are marked `compressed`, not deleted (audit trail)
6. **Branching**: Users can fork from any node, creating a new path with inherited context
7. **Retry**: Failed agent nodes can be retried, creating new attempt nodes

#### Context Assembly
When building context for an LLM call, the system walks from the target leaf node back to the root, collecting all nodes on the path. Summary nodes substitute for the lanes they represent.

#### Turn semantics (current default)

- Treat a user↔LLM exchange as a single `turn_id`: the `user_message`, the assistant loop/tool/task nodes, and the final `agent_message/character_message` share the same turn (do not split into separate user-turn + assistant-turn).
- When executing a node and creating downstream nodes for that exchange, prefer `graph.mutate!(turn_id: node.turn_id) { |m| ... }` so the new nodes inherit the same turn.
- UI primitives:
  - “Messages list / fetch last N messages” → `lane.message_page(limit: ...)` (message-level keyset paging; does not guarantee turn alignment).
  - “Transcript / scroll by turns” → `lane.transcript_page(limit_turns: ...)` (turn-level keyset paging).

#### Safety limits (hard caps)

- `lane.message_page(...)` has an internal “max scanned candidate nodes” safety belt, so a page may contain fewer than `limit` (extreme case: empty). ENV: `DAG_MAX_MESSAGE_PAGE_SCANNED_NODES`.
- `lane.context_for(...)` / `graph.context_for(...)` have internal hard caps on candidate window size (nodes/edges); when exceeded they raise `DAG::SafetyLimits::Exceeded`. ENV: `DAG_MAX_CONTEXT_NODES` / `DAG_MAX_CONTEXT_EDGES`.

#### Change policy

This is the current Milestone 1 design. If real product requirements make it hard to land features, destructive changes are allowed after discussion (keep code/tests/docs aligned; avoid long-lived compatibility layers).

### UUID Primary Keys

All tables use UUIDs (UUIDv7 format, base36-encoded as 25-char strings):
- Custom fixture UUID generation maintains deterministic ordering for tests
- Fixtures are always "older" than runtime records
- `.first`/`.last` work correctly in tests

### Background Jobs (Solid Queue)

Database-backed job queue (no Redis):
- Jobs automatically capture/restore `Current.account`
- Solid Queue for all async processing

### Core Models

**Account** → The tenant/organization
- Has users, conversations
- Multi-tenancy root

**Identity** → Global user (email)
- Can have Users in multiple Accounts

**User** → Account membership
- Belongs to Account and Identity
- Has role (owner/admin/member/system)

**Conversation** → A DAG-structured agent session
- Belongs to Account
- Has many DAG nodes and edges
- Tracks overall status and metadata

**Dag::Node** → A single node in the conversation graph
- Has type, state, content, metadata
- Supports retry (for agent nodes)
- Can be compressed (replaced by summary)

**Dag::Edge** → A directed edge between two nodes
- Has type (sequence, dependency, branch)
- Enforces acyclicity via database constraints and model validation

**Event** → Records all significant actions
- Polymorphic association to changed object
- Drives activity timeline, notifications
- Has JSON `particulars` for action-specific data

## Tools

### Chrome MCP (Local Dev)

URL: `http://localhost:3000`
Login: admin@example.com (passwordless magic link auth - check rails console for link)

Use Chrome MCP tools to interact with the running dev app for UI testing and debugging.

## Coding Style

@STYLE.md

## Cursor Cloud specific instructions

@CURSOR.md

### Testing

- `bin/rails test` runs 939+ unit/integration tests in parallel (4 workers)
- `bin/rubocop` for linting (340 files)
- `bin/ci` for the full CI suite (rubocop → bundler-audit → brakeman → tests → seed validation)
- System tests (`bin/rails test:system`) require Chrome/Chromium (not pre-installed in cloud)
