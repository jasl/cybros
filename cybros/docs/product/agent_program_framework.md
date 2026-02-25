# Agent Program Framework

An **Agent Program** is a git-managed repository that defines an agent's behavior: who it is, how it thinks, what tools it uses, and how it evolves. Every agent in Cybros — from a simple chatbot to a self-modifying coding agent — is an Agent Program.

## Design Principles

- **Files are the API**: Agent behavior is defined by files in a git repo, not database records or platform UI. This makes agents versionable, diffable, forkable, and portable.
- **Two tiers, same framework**: Simple agents are just config + prompt templates (no sandbox needed). Complex agents add hooks and custom tools (executed in sandbox). Both use the same repo structure.
- **Language freedom**: Hooks and custom tools are executables. Ruby, Python, Node, shell — anything that reads JSON from a file and writes JSON to a file.
- **Deployable anywhere**: Agent programs can run on any territory (host machine) the user controls. The program repo is a Nexus facility.
- **Gradual externalization**: Phase 0 reads agent files and feeds them as data into the existing AgentCore pipeline. Phase 1 adds hooks that can override the data. No big-bang rewrite of AgentCore.

## Repository Structure

```
my-agent/
├── agent.yml                    # Required: metadata, model, capabilities
│
├── AGENT.md                     # Operating instructions (loaded every turn)
├── SOUL.md                      # Persona definition: tone, boundaries, identity
├── USER.md                      # User profile: who the user is, preferences
│
├── prompts/
│   └── system.md.liquid         # System prompt template (Liquid)
│
├── personas/                    # Optional: switchable persona variants
│   ├── coder/
│   │   ├── SOUL.md
│   │   └── system.md.liquid
│   └── writer/
│       ├── SOUL.md
│       └── system.md.liquid
│
├── tools/                       # Optional: agent-specific tools
│   ├── fortune.yml              # Tool schema (JSON Schema)
│   └── fortune.rb               # Tool implementation (executable)
│
├── hooks/                       # Optional: lifecycle hooks (executable)
│   ├── on_conversation_start
│   ├── before_inference
│   └── after_tool_call
│
├── skills/                      # Optional: agent-bundled skills (markdown)
│   └── astrology.md
│
├── data/                        # Agent-local persistent data
│   ├── facts.yml                # Persistent KV (no decay, git-tracked, read-only from Cybros)
│   └── lorebook.yml             # Character/knowledge data
│
├── memory/                      # Runtime memory (managed by system)
│   └── YYYY-MM-DD.md            # Daily memory log (human-readable diary)
│
└── .git/                        # Version history
```

### Core Files

| File | Required | Loaded | Purpose |
|------|----------|--------|---------|
| `agent.yml` | Yes | On agent load | Metadata, model selection, tool allowlist, capabilities |
| `AGENT.md` | Yes | Every turn | Operating instructions: how the agent should behave, use tools, manage memory |
| `SOUL.md` | No | Every turn | Persona definition: personality, tone, boundaries, identity |
| `USER.md` | No | Every turn | User profile: name, preferences, context about the human |
| `prompts/system.md.liquid` | No | Every turn | System prompt template. If absent, prompt is assembled from AGENT.md + SOUL.md |

### Relationship to OpenClaw Workspace

Inspired by OpenClaw's agent workspace concept (AGENTS.md, SOUL.md, USER.md, IDENTITY.md, TOOLS.md, memory/ logs). Key differences:

- Cybros adds `agent.yml` for structured machine-readable config (model, tools, capabilities)
- Cybros supports `hooks/` for executable lifecycle scripts
- Cybros supports `tools/` for agent-defined custom tools
- Cybros uses Liquid templates for dynamic prompt generation
- Memory is dual: file-based daily logs (`memory/`) for context loading + pgvector-based semantic search (`memory_search` tool) for long-term retrieval

### agent.yml Schema

```yaml
name: "my-agent"
description: "A helpful coding assistant"

model:
  default: "claude-sonnet-4-20250514"
  prefer:
    - "claude-sonnet-4-20250514"
    - "gpt-4.1"

tools:
  # Allowlist of Cybros base tools this agent wants to use.
  # Effective tools = intersection(this list, Cybros available tools)
  allow:
    - memory_search
    - memory_store
    - code_execution
    - read_file
    - write_file
    - edit_file
    - bash
    - glob
    - grep
    - web_search
    - web_fetch

  # Agent-specific tools defined in tools/ directory.
  # These execute in the agent's own sandbox environment.
  custom:
    - fortune

personas:
  default: null                  # null = use root SOUL.md
  available:
    - coder
    - writer
  router: auto                   # auto | explicit | hook

hooks:
  before_inference: true
  after_tool_call: false
  on_conversation_start: true

capabilities:
  self_modify: true              # Agent can edit its own repo
  spawn_subagents: false         # Agent can create sub-agents
```

### Model Resolution

Agent programs should use full model names in `model.prefer` (e.g., `claude-sonnet-4-20250514`, not just `claude`).

The `model.prefer` list resolves against configured LLM providers:

1. Iterate the prefer list in order
2. For each model name, find all `LlmProvider` records whose `model_allowlist` includes this model
3. If multiple providers match, pick the one with the highest `priority`
4. Use the first model in the prefer list that has a matching provider
5. If no match found, use the system default model

The `model_allowlist` is a required string array on `LlmProvider`. A provider only serves models explicitly listed. The UI provides a "Fetch Models" button to query the provider's `/v1/models` endpoint to help populate the list (not all providers support this API).

## Prompt Assembly

### Safety: Timeout and Isolation

AgentProgramLoader reads files from disk (Phase 0) or via Nexus (Phase 1). To prevent agent programs from blocking Cybros:

- **File loading timeout**: AgentProgramLoader enforces a read timeout (default: 5s). If files can't be read in time, the conversation run fails with a clear error.
- **Hook execution timeout**: Hooks run via Nexus directives with a configurable timeout (default: 30s). If the hook times out, its output is discarded and static config is used as fallback.
- **Malformed output**: If hook output JSON is invalid or fails schema validation, it's discarded with a warning logged. Static config fallback applies.
- **Nexus unreachable**: If no Nexus territory is available (offline, unregistered), tools/hooks that require Nexus fail gracefully. The conversation run reports the error; in-process tools still work.

These safeguards ensure a broken or unresponsive agent program never hangs Cybros.

### Assembly Flow

When the agent needs to respond, a `PromptConfig` is assembled from agent program files and fed into AgentCore's existing `SystemPromptSectionsBuilder`:

```
AgentProgramLoader reads files
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ PromptConfig                                         │
│                                                      │
│  sections (stable → dynamic order for cache):        │
│    1. AGENT.md content (operating instructions)      │  ← stable prefix
│    2. SOUL.md content (persona, or persona variant)  │  ← stable prefix
│    3. USER.md content (user profile)                 │  ← stable prefix
│    4. prompts/system.md.liquid (rendered template)   │  ← mostly stable
│    5. Tool descriptions (from effective tool set)    │  ← stable per-agent
│    6. Loaded skills (from skills/ directory)         │  ← stable per-agent
│    7. Hook output (from before_inference, Phase 1+)  │  ← dynamic tail
│  effective_tools: [intersected + custom tool defs]   │
│  model_preference: [from agent.yml]                  │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
         SystemPromptSectionsBuilder
         (existing AgentCore, adapted to accept PromptConfig)
                       │
                       ▼
               Final system prompt
```

**Prompt cache awareness**: The section order is deliberately stable-first, dynamic-last. LLM providers (Anthropic, OpenAI) cache prompt prefixes — if the first N tokens are identical across requests, only the new tokens are billed at full price. By keeping AGENT.md, SOUL.md, USER.md, tool descriptions, and skills at the top (these rarely change between turns), and placing hook output and conversation messages at the end, we maximize cache hit rate. Avoid injecting per-turn noise (timestamps, random IDs) into stable sections.

If `prompts/system.md.liquid` exists, it's the primary system prompt and the markdown files provide context sections. If it doesn't exist, the markdown files are concatenated in order.

### Liquid Template Variables

Templates have access to:

```liquid
{{ agent.name }}                 # Agent name from agent.yml
{{ agent.description }}          # Agent description
{{ user.name }}                  # From USER.md frontmatter or User model
{{ conversation.id }}            # Current conversation ID
{{ turn.id }}                    # Current turn ID
{{ persona.name }}               # Current persona name (null if default)
{{ facts.key_name }}             # From data/facts.yml (read-only, git-tracked)
{{ args.custom_key }}            # From AgentProgram.args (JSONB, set at creation)
```

## Tool Model

### Allowlist Intersection

The agent program declares which Cybros base tools it wants. The effective tool set is the intersection of what the agent requests and what Cybros makes available:

```
Cybros base tools:       [memory_search, memory_store, code_execution, bash, ...]
Agent tool allowlist:    [memory_search, code_execution, my_fortune]
                         ──────────────────────────────────────────
Effective Cybros tools:  [memory_search, code_execution]   (intersection)
Agent custom tools:      [my_fortune]                      (from tools/ dir)
Final tool set:          [memory_search, code_execution, my_fortune]
```

### Hook Tool Modifications

A `before_inference` hook can dynamically expand the tool set within the Cybros base tool pool:

```json
{
  "tool_additions": ["grep", "git_diff"],
  "tool_removals": ["web_search"]
}
```

`tool_additions` can add Cybros base tools not in the static allowlist (expanding the intersection). `tool_removals` can remove tools for this turn. This is a per-turn override; the static allowlist remains unchanged.

### Custom Tools

Agent-defined tools live in `tools/`. Tool name maps to files by convention: `fortune` → `tools/fortune.yml` (schema) + `tools/fortune.rb` (implementation).

**Schema file** (`tools/fortune.yml`):
```yaml
name: fortune
description: "Generate a fortune based on zodiac sign"
parameters:
  type: object
  properties:
    sign:
      type: string
      enum: [aries, taurus, gemini, cancer, leo, virgo,
             libra, scorpio, sagittarius, capricorn, aquarius, pisces]
    aspect:
      type: string
      enum: [love, career, health, general]
      default: general
  required: [sign]
```

**Implementation** (`tools/fortune.rb`):
```ruby
#!/usr/bin/env ruby
require "json"

input = JSON.parse(File.read(ENV["CYBROS_TOOL_INPUT"]))
sign = input.dig("arguments", "sign")
aspect = input.dig("arguments", "aspect") || "general"

result = { fortune: "Today is a great day for #{sign}!", aspect: aspect }

File.write(ENV["CYBROS_TOOL_OUTPUT"], JSON.generate(result))
```

Custom tools are executed via Nexus directives in the agent's facility. Phase 0 does not support custom tools (Conduits not yet ported). Phase 1 enables them.

## Hook System

Hooks are lifecycle scripts that run at specific points during agent execution. They allow dynamic behavior that can't be expressed in static config. **Hooks require Nexus (Phase 1+).**

### Hook Lifecycle

```
Conversation starts
  → [on_conversation_start] hook
  → Agent ready

User sends message
  → Context assembly
  → [before_inference] hook
  → LLM inference (streaming)
  → Response complete

Tool call returned
  → [after_tool_call] hook
  → Continue tool loop or respond
```

### Hook Protocol

**Input**: Written to a JSON file at the path in `$CYBROS_HOOK_INPUT`.

```json
{
  "event": "before_inference",
  "conversation_id": "01JMXYZ...",
  "turn_id": "01JMXYZ...",
  "recent_messages": [
    { "role": "user", "content": "Help me refactor this code" },
    { "role": "assistant", "content": "I'll take a look..." }
  ],
  "current_persona": null,
  "agent_state": { "session_count": 5, "last_topic": "ruby refactoring" },
  "available_tools": ["memory_search", "code_execution", "bash"],
  "args": { "custom_key": "value" }
}
```

**Output**: Written by the hook to the path in `$CYBROS_HOOK_OUTPUT`.

```json
{
  "system_prompt_append": "Focus on Ruby style and performance.",
  "persona_override": "coder",
  "tool_additions": ["grep", "git_diff"],
  "tool_removals": [],
  "state_updates": { "last_topic": "ruby refactoring" },
  "model_override": null
}
```

All output fields are optional. Omitted fields mean "no change." The hook output is **merged** with the static PromptConfig, not a replacement.

### Execution

Hooks are executed asynchronously via Nexus directives:

1. Cybros creates a directive record in its DB: `command: "hooks/before_inference"`, `env: { CYBROS_HOOK_INPUT: ..., CYBROS_HOOK_OUTPUT: ... }`
2. Nexus polls Cybros, claims the directive, executes it in the agent's facility
3. Nexus reports the result (including output file contents) back to Cybros
4. Cybros reads the hook output JSON from the directive result
5. If hook fails or times out (default: 30s), fall back to static config

Hook execution is managed through ActiveJob (Solid Queue). The conversation run job creates the directive record, polls for completion, then continues with the agent execution pipeline.

## Memory: Two Systems

Agent programs have access to two complementary memory systems:

| System | Storage | Decay | Use Case |
|--------|---------|-------|----------|
| **Daily log** (`memory/YYYY-MM-DD.md`) | Files in agent repo (git-tracked) | No | Human-readable session diary. Loaded into context on session start. Agent writes daily summaries here. |
| **Semantic memory** (pgvector) | Database (`agent_memory_entries`) | Yes (configurable) | Vector search via `memory_search` tool. For long-term factual recall across conversations. |

The daily log is the agent's diary — short, curated, loaded every session. Semantic memory is the searchable archive — large, relevance-ranked, queried on demand.

### Facts vs Memory

`data/facts.yml` is a **static** key-value store in the agent repo. It's git-tracked and read-only from Cybros's perspective (only the agent can modify it via self-modification tools). Facts are for persistent truths: user preferences, workspace paths, configured behaviors. They don't decay.

Future: a **runtime Facts KV** (via internal MCP) will allow agents to read/write facts programmatically without git commits.

## Self-Modification

When `capabilities.self_modify: true`, the agent has access to tools that operate on its own repository:

| Tool | Description |
|------|-------------|
| `agent_read_self` | Read any file in the agent's repo |
| `agent_write_self` | Write/create a file in the agent's repo |
| `agent_edit_self` | Edit an existing file (patch-style) |
| `agent_commit` | Git commit changes with message |
| `agent_diff` | Show uncommitted changes |
| `agent_revert` | Revert to a previous commit |
| `agent_log` | Show git commit history |

### Self-Modification Flow

```
User: "Make yourself more concise"
  → Agent uses agent_read_self to read SOUL.md
  → Agent uses agent_write_self to update SOUL.md
  → Agent uses agent_commit to save changes
  → Next turn uses the updated SOUL.md
```

Agent programs always read the latest files on each turn. Mid-conversation modifications take effect starting from the next turn (the current turn completes with the version that was loaded at its start).

### Health Check

After self-modification, the system runs a smoke test:

1. Send a predefined test message to the agent
2. Verify the agent responds coherently (no crash, no empty response)
3. If the test fails, auto-revert to the previous commit
4. Notify the user of the revert

### Version Management

- All changes are git commits with descriptive messages (via ruby-git)
- UI shows commit history with diffs
- One-click revert to any previous version
- Optional: sync to a GitHub repo for backup/collaboration

## Agent Program SDK (cybros-agent)

A Ruby reference implementation lives in the monorepo at `cybros-agent/`. Structure:

```
cybros-agent/
├── lib/
│   └── cybros_agent.rb          # SDK: hook/tool DSL, I/O helpers
├── profiles/                    # Bundled agent profiles
│   ├── default-assistant/       # Phase 0
│   │   ├── agent.yml
│   │   ├── AGENT.md
│   │   ├── SOUL.md
│   │   └── prompts/
│   │       └── system.md.liquid
│   ├── coder/                   # Phase 1 (requires Nexus)
│   │   ├── agent.yml
│   │   ├── AGENT.md
│   │   ├── SOUL.md
│   │   └── prompts/
│   │       └── system.md.liquid
│   └── mac-assistant/           # Phase 1 (requires Nexus + macOS territory)
│       ├── agent.yml
│       ├── AGENT.md
│       ├── SOUL.md
│       └── prompts/
│           └── system.md.liquid
└── Gemfile
```

SDK usage in hooks:

```ruby
#!/usr/bin/env ruby
require "cybros_agent"

CybrosAgent.hook do |input|
  {
    system_prompt_append: "Be extra helpful today.",
    state_updates: { mood: "cheerful" }
  }
end
```

SDK usage in custom tools:

```ruby
#!/usr/bin/env ruby
require "cybros_agent"

CybrosAgent.tool do |input|
  sign = input.arguments["sign"]
  { fortune: "Great day for #{sign}!" }
end
```

The SDK handles file I/O, JSON parsing, error handling, and provides a clean DSL. Agent programs are not required to use it — any language that reads/writes JSON files works.

## Git Management

Agent program repos are managed via the `ruby-git` gem:

- **Phase 0** (local): Git operations happen in the Cybros process. Repos stored under `Rails.root.join("storage/agent_programs/")`.
- **Phase 1** (Nexus): Git operations happen via Nexus directives on the target territory. Repos are Nexus facilities.

### Creating an Agent Program

1. **From bundled profile**: Copy files from `cybros-agent/profiles/<name>/` into a new directory, `git init`, `git commit`.
2. **From GitHub**: `git clone` from a GitHub URL into a new directory.
3. **Blank**: Create directory with minimal `agent.yml` + `AGENT.md`, `git init`.

The `AgentProgram` model stores:
- `name`, `description`
- `profile_source` (bundled profile name, GitHub URL, or "blank")
- `local_path` (Phase 0) or `facility_id` (Phase 1)
- `args` (JSONB, optional parameters passed to Liquid templates)
- `active_persona` (current persona, nullable)

## Deployment

Agent programs can be deployed to any territory the user controls:

- **Local development**: Agent repo on the Cybros server filesystem (Phase 0)
- **Same machine**: Agent repo as a Nexus facility on the local territory
- **Remote host**: Agent repo on a user's personal machine, GPU workstation, etc.
- **Multiple territories**: Same agent program deployed to different hosts for redundancy or capability access

The platform resolves which territory to use based on:
1. Agent program's configured territory (if explicit)
2. Capability requirements (e.g., macOS automation needs a macOS territory)
3. Resource availability and load

## Workspace (for Coding Agents)

Coding agents need a project workspace — the directory they read/write code in.

- `AgentProgram` or `Conversation` can have an associated workspace path
- The workspace is stored as a persistent fact (KV) so the agent doesn't have to rediscover it each turn
- Phase 0: workspace is a local directory path (e.g., `/Users/jasl/projects/my-app`)
- Phase 1: workspace is a Nexus facility mapped to the directory
- Security: Phase 0/1 with host driver — no path restriction (single user trusts themselves). Sandbox drivers enforce filesystem boundaries via mount mapping.

Workflow:
1. User tells the agent: "Work on /path/to/my-project"
2. Agent validates the path exists
3. Agent stores the path as a fact in KV
4. All coding tools (read_file, bash, etc.) execute relative to this path
5. Path persists across turns and conversations with this agent

## Bundled Agent Programs

Cybros ships with bundled profiles in `cybros-agent/profiles/`:

| Agent | Description | Key Tools |
|-------|-------------|-----------|
| `default-assistant` | General-purpose chat agent | memory_search, memory_store, web_search |
| `coder` | Coding agent (Codex/OpenCode-like) | read_file, write_file, edit_file, bash, glob, grep, git_* |
| `mac-assistant` | macOS automation agent | run_applescript, open_url, take_screenshot, run_shortcut |

These serve as both functional defaults and reference implementations for building custom agents.
