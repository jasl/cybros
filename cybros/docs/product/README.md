# Cybros Product Definition

## Vision

Cybros is an experimental AI agent platform built on an **immutable base + plugins + programmable agents** architecture. The goal is not self-evolution itself, but to unleash LLM and agent capabilities to **morph into any form of software product** — from coding agents to roleplay companions to automation assistants — without permanent forks.

Key principles:

- **Programmable agents over hardcoded behaviors**: Agent behavior is defined by code and config in git-managed repositories, not baked into the platform.
- **Sandbox-backed execution**: Agents run code in isolated environments. Custom tools, hooks, and prompt programs execute in sandboxes.
- **Security trade-offs accepted**: Prioritize agent capability and user productivity. Do best-effort security with rollback capability, not enterprise-grade lockdown.
- **Simplicity over completeness**: Ship working software. Avoid premature abstraction and over-engineering.
- **Usage-driven improvement**: Comprehensive observability feeds the improve-and-iterate loop.

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     Cybros (Rails)                            │
│                                                              │
│  ┌─────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
│  │ Web UI  │  │ Conversations │  │ Agent Program Loader    │ │
│  │ Hotwire │  │ DAG Engine   │  │ (reads agent repos)     │ │
│  └────┬────┘  └──────┬───────┘  └────────────┬────────────┘ │
│       │              │                        │              │
│  ┌────┴──────────────┴────────────────────────┴────────────┐ │
│  │                    AgentCore                             │ │
│  │  Executors · Tool Loop · Prompt Builder · Context Mgmt  │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                  │
│  ┌────────────────────────┴────────────────────────────────┐ │
│  │              Conduits (control plane)                    │ │
│  │  Territories · Facilities · Directives · Policies       │ │
│  └────────────────────────┬────────────────────────────────┘ │
└───────────────────────────┼──────────────────────────────────┘
                            │ Poll-based (mTLS)
┌───────────────────────────┼──────────────────────────────────┐
│                     Nexus (Go daemon)                        │
│  Polls for directives · Executes in sandbox · Reports back   │
│                                                              │
│  Sandbox drivers: host (now) · bwrap · container · microVM   │
│  Platforms: Linux (amd64/arm64) · macOS (arm64)              │
└──────────────────────────────────────────────────────────────┘

Mothership (separate Rails app): Lightweight prototype of the Conduits
control plane. Used for Nexus development and protocol experimentation.
Not a production component — its functionality is merged into Cybros.
```

Communication is **pull-based**: Nexus polls the control plane (Cybros) via `POST /conduits/v1/polls`. No inbound ports required on the Nexus side.

## Current State

### What's built and solid

| Component | Status | Description |
|-----------|--------|-------------|
| DAG Engine | Production-ready | Scheduling, execution, fork/merge, compression, context assembly, streaming, turns. 939+ tests. |
| AgentCore | Production-ready | LLM execution, tool loop with repair, provider failover, memory (pgvector), skills, subagent orchestration, prompt building with budget management. |
| Conduits Protocol | Designed & implemented | Pull-based API with lease management, log streaming, facility model. OpenAPI spec. |
| Nexus | Phase 0.5 | Host driver (no isolation), directive lifecycle, log streaming, facility management. |
| Mothership | Dev-complete | Prototype Conduits control plane. Full API, policy model, audit events. Used as reference for porting into Cybros. |

### What's not built

- User/auth system
- LLM provider management
- Web UI (only bare `home#index`)
- Conversation management (controllers, views, API)
- Agent Program framework
- Nexus integration in Cybros
- Programmable agent self-modification
- macOS automation tools
- Coding agent tools
- Observability dashboard
- Plugin/extension system
- Channel integrations (Telegram, Discord, etc.)

## Core Concepts

| Concept | Definition |
|---------|-----------|
| **Account** | The instance tenant. Holds global configuration (LLM providers, defaults, settings). Single account in Phase 0. |
| **Identity** | Global user identity (email-based). Enables future OAuth via `UserAssociatedAccount`. |
| **User** | Account-scoped membership. Belongs to Identity and Account. Has role (owner/admin/member). |
| **Conversation** | DAG-backed conversation container. Belongs to an Agent Program. |
| **ConversationRun** | Tracks a single agent execution lifecycle (queued → running → succeeded/failed/canceled). |
| **Agent Program** | Git-managed repository defining agent behavior: config, prompts, hooks, custom tools. See [Agent Program Framework](agent_program_framework.md). |
| **LLM Provider** | Configuration for an LLM API endpoint: base URL, API key, model allowlist, priority. |
| **Persona** | Switchable behavior config within an Agent Program (different system prompt, tool set, voice). |
| **Territory** | A registered Nexus instance (a host machine). |
| **Facility** | Persistent workspace directory on a territory. Used for project repos and agent program repos. |
| **Directive** | A unit of work (shell command) executed in a facility by Nexus. |

## Acceptance Targets

1. **End-to-end product flow**: Human opens browser → creates conversation → chats with agent → agent uses tools → streaming responses.
2. **Coding agent**: Codex/OpenCode-like agent that reads files, writes code, runs tests, fixes bugs in a project repo.
3. **macOS automation**: Agent automates macOS apps via AppleScript, Shortcuts, and system commands.
4. **Multi-agent / swarm**: Coordinator agent orchestrates specialist agents for complex tasks.
5. **Multi-persona agent**: Single agent switches personas based on user intent (coder, writer, researcher, etc.).
6. **Roleplay agent**: RisuAI-like agent with character cards, lorebook, long-term memory, personality.
7. **Game agent**: Astrology fortune-telling agent with custom tools and structured output.

## Documents

- [Agent Program Framework](agent_program_framework.md) — The core differentiator: how agent programs are structured, executed, and self-modified.
- [Roadmap](roadmap.md) — Phased implementation plan with acceptance criteria.
