# Cybros

This file provides guidance to AI coding agents working with this repository.

## What is Cybros?

Cybros is an experimental AI Agent platform that models agent conversations as dynamic Directed Acyclic Graphs (DAGs). Instead of treating agent interactions as linear chat logs, Cybros represents every action — user messages, agent responses, tool calls, sub-agent tasks, and context summaries — as typed nodes in a DAG. A workflow engine schedules agent execution based on graph topology, enabling parallel task execution, dependency tracking, conversation branching, and lane compression for context management.

The platform is multi-tenant (URL path-based) and designed for observability: the DAG structure makes it possible to visualize, monitor, and audit every step of an agent's reasoning and actions.

## Development Commands

### Setup and Server
```bash
bin/setup              # Initial setup (installs gems, creates DB, loads schema)
bin/dev                # Start development server (runs on port 3000)
```

Development URL: http://localhost:3000
Login with: admin@example.com (development fixtures), password: Passw0rd

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

### Multi-Tenancy (URL-Based)

Cybros uses **URL path-based multi-tenancy**:
- Each Account (tenant) has a unique `external_account_id` (7+ digits)
- URLs are prefixed: `/{account_id}/conversations/...`
- Middleware extracts the account ID from the URL and sets `Current.account`
- The slug is moved from `PATH_INFO` to `SCRIPT_NAME`, making Rails think it's "mounted" at that path
- All models include `account_id` for data isolation
- Background jobs automatically serialize and restore account context

**Key insight**: This architecture allows multi-tenancy without subdomains or separate databases, making local development and testing simpler.

### Authentication & Authorization

**Passwordless magic link authentication**:
- Global `Identity` (email-based) can have `Users` in multiple Accounts
- Users belong to an Account and have roles: owner, admin, member, system
- Sessions managed via signed cookies

### DAG-Based Conversation Engine (Core Domain)

The central abstraction of Cybros is the **conversation DAG**. Each conversation is a directed acyclic graph where every interaction becomes a node.

### Public API boundary (important)

When working on DAG-related code (engine, app integration, tests, scripts):

- Prefer **Public API** over touching internal tables/associations directly.
- If the Public API is missing a capability, add/adjust the Public API + tests/doc, then use it (avoid “hacky” direct SQL/`update_columns` from the App domain).

Doc: `docs/dag_public_api.md`

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
