# Conversation Agent Runtime Simplification Design

## Status

Approved design notes for simplifying the Cybros agent runtime around `Conversation`, `Agent`, `RecognizedDeployment`, and conversation-owned logical workspaces.

This design intentionally deprioritizes multi-host target/deployment isolation for V1. The immediate goal is to prove:

- programmable agents are usable in the product
- the DAG engine can satisfy real agent scheduling needs
- the default agent path is simple enough to ship and debug

## Problem

The current runtime model exposes or depends on too many moving parts at once:

- `AgentProgram`
- `AgentDeployment`
- `ExecutionLocation`
- `Workspace`
- `ExecutionTarget`

That model supports a more ambitious future where the agent runtime and execution target can be isolated across environments, but it creates too much product and implementation complexity for the current validation phase.

V1 needs a smaller runtime model that:

- keeps conversation-level agent behavior understandable
- preserves enough runtime identity for stats and debugging
- supports uploaded files and a persistent working context
- still works when the agent is externally managed or not directly controlled by Cybros

## Goals

- collapse the public runtime model to `Conversation -> Agent -> Turn/Run -> RecognizedDeployment`
- keep per-conversation persistent work context without requiring every agent to expose a real local directory
- let the default local agent follow an OpenClaw-like model with a persistent conversation workspace
- make uploaded files first-class through Active Storage, ordered attachment manifests, and explicit transfer tasks
- pin each turn to a recognized runtime identity without storing a large full snapshot on every turn
- attach runtime stats to recognized runtime identities
- allow `RecognizedDeployment` records to be retired or purged without breaking system integrity

## Non-Goals

- no strong security proof that agent-reported runtime metadata is truthful
- no V1 support for switching agents mid-conversation
- no V1 support for target/deployment host separation as a product workflow
- no requirement that every external agent expose a local filesystem path or real mounted workspace
- no V1 workspace cloning, snapshotting, or rollback

## Breaking Cutover

This simplification is intentionally a breaking cutover, not a compatibility migration.

Assumptions approved for V1:

- database reset is allowed
- overfit compatibility layers are not required
- obsolete runtime models, admin surfaces, and docs should be deleted rather than hidden

That means the implementation should prefer direct replacement over adapter layers when the old runtime model exists only to preserve abandoned product semantics.

## Core Product Model

### Public Concepts

V1 should expose only these primary runtime concepts:

- `Conversation`
- `Agent`
- `RecognizedDeployment`

`Conversation` is the durable user-visible unit.

`Agent` is the user-selected runtime endpoint/configuration.

`RecognizedDeployment` is the runtime identity Cybros observes during a handshake and uses for turn-level pinning, debugging, and statistics.

### Internal Concepts

The current `AgentProgram`, `AgentDeployment`, `ExecutionLocation`, `Workspace`, and `ExecutionTarget` concepts describe the old runtime model and should be removed from the V1 product path.

In particular:

- conversations should not expose execution-target switching
- users should not reason about deployment activation state directly
- workspaces should no longer appear as general infrastructure objects in the main product flow
- obsolete runtime models, controllers, settings pages, routes, and docs should be deleted once the new model is in place

## Conversation And Agent Binding

### Conversation Binds To Agent

Each `Conversation` binds to a single `Agent`.

That binding means:

- the conversation defaults to that agent for all future turns
- the conversation owns a single logical workspace
- uploaded attachments belong to that conversation context

V1 does not support switching agents inside an existing conversation.

If the user wants to use a different agent, the supported path is:

- create a new conversation
- optionally branch into a new conversation with a different agent later

`Agent` is also the configured runtime-policy anchor for the conversation.

That means V1 agent records should own:

- runtime endpoint and auth configuration
- default capability declarations
- execution-capacity policy for that configured runtime path

### Conversation Entry Flow

Because a conversation cannot exist without an `Agent`, V1 should make agent selection explicit at conversation creation time.

Product implications:

- the dashboard is the primary entry surface for starting a conversation
- the dashboard should list selectable `Agent` records
- each listed `Agent` should expose a `New conversation` action
- generic dashboard or shell-level `New chat` affordances without agent context should be removed
- the conversations index becomes a browsing/history surface, not the primary creation flow

This keeps the public mental model aligned with the data model: the user starts from an `Agent`, then gets a `Conversation` bound to that `Agent`.

### Agent Upgrades

Updating an `Agent` changes the configured runtime endpoint, auth, capability defaults, or execution-capacity policy used for future turns of conversations bound to that `Agent`.

That does not rewrite historical runtime bindings.

Rules:

- future turns resolve from the conversation's currently bound `Agent`
- in-flight turns remain pinned to the `RecognizedDeployment` selected at turn start
- if an agent upgrade changes the observed runtime identity mid-turn, the turn must drift/fail safe rather than silently continue
- historical `RunDraft` and `ConversationRun` rows must continue to expose the runtime identity captured when they were created

### Turn/Run Binds To RecognizedDeployment

Each turn-level execution unit, represented today by `RunDraft` and `ConversationRun`, should bind to a single `RecognizedDeployment`.

This keeps history accurate even if the configured `Agent` changes later.

The turn-level rule is:

- a single turn must execute against one stable recognized runtime identity
- if that identity changes during the turn, the turn is considered drifted and must not continue automatically

## Execution Capacity

V1 must remove execution-capacity dependency on `ExecutionTarget`.

The old model attached execution capacity to `ExecutionLocation` and `ExecutionTarget`. That is not compatible with the simplified runtime, because the user-visible flow no longer selects execution targets and the runtime target is now implicitly the agent host.

The replacement rule is:

- execution capacity is configured on `Agent`
- turn planning resolves execution capacity from the conversation's bound agent
- recognized runtime identities inherit that policy for the duration of the turn

Reasons:

- capacity policy must be available before turn planning completes
- `RecognizedDeployment` is discovered at runtime and is too late to be the sole source of planned capacity policy
- capacity should remain stable across recognized deployment churn when the configured agent endpoint is still logically the same target

This does not prevent future finer-grained capacity policy.

It only defines the V1 anchor:

- configured runtime capacity belongs to `Agent`

## RecognizedDeployment

### Purpose

`RecognizedDeployment` is not a configured object.

It is a runtime identity record created from agent handshake responses. It exists to support:

- turn-level pinning
- debugging
- statistics
- drift detection

### Trust Model

`RecognizedDeployment` must be treated as `trust-on-observation`.

It records what the agent reported. It is not attestation and it is not a security proof.

This means V1 explicitly accepts these trade-offs:

- agent metadata may be wrong
- agent metadata may be forged
- Cybros cannot prove that an external agent is truly on the expected host

That is acceptable for V1 because the goal is operability and observability, not strong runtime attestation.

### Fields

V1 `RecognizedDeployment` should contain a normalized subset of handshake identity and capability data.

Required identity and compatibility fields:

- `agent_id`
- `identity_digest`
- `recognized_deployment_key`
- `deployment_fingerprint`
- `protocol_version`
- `supported_methods`
- `agent_sdk_version`
- `agent_capabilities_version`
- `capability_snapshot_digest`
- `supports_upload`

Optional debug fields:

- `hostname`
- `container_id`
- `git_sha`
- `build_id`
- `image_digest`
- `booted_at`

### Deduplication

`RecognizedDeployment` records should be deduplicated by normalized identity fields rather than recreated on every turn.

In practice:

- if the normalized hard-identity payload is unchanged, reuse the existing record
- if hard-identity fields change, create a new record

This avoids per-turn database bloat while preserving a stable runtime dimension for statistics.

### Safe Deletion

`RecognizedDeployment` must be safely deletable without breaking historical integrity.

To support that:

- `ConversationRun` should store both `recognized_deployment_id` and `recognized_deployment_key`
- statistics facts should key primarily on `recognized_deployment_key`
- `recognized_deployment_id` should be nullable in long-lived derived data where deletion needs to be safe

Deletion modes:

- `retire`
  - default path
  - mark as retired or deleted
  - keep minimal identifying fields needed for stats and historical display
  - optionally clear sensitive debug fields
- `purge`
  - restricted maintenance path
  - only allowed when no active runtime state depends on the record
  - historical rows keep working because they retain `recognized_deployment_key`

`RecognizedDeployment` therefore behaves like a tombstone-capable dimension table rather than a hard runtime anchor.

## Turn Handshake And Drift Rules

### Turn Start

At the beginning of a turn:

1. Cybros resolves the conversation's configured `Agent`
2. Cybros performs runtime handshake against that agent
3. Cybros normalizes the handshake response
4. Cybros resolves or creates the matching `RecognizedDeployment`
5. the turn binds to that `RecognizedDeployment`

The current runtime already does two related things:

- `capabilities.handshake` during run-draft preparation
- `initialize` before each lifecycle RPC invocation

V1 should keep that structure, but reinterpret the observed runtime identity as `RecognizedDeployment` rather than a user-managed deployment object.

### Turn Stability

Once a turn is bound, later lifecycle or tool RPC calls must continue to match the same recognized runtime identity.

The hard identity set for drift detection should include at least:

- `deployment_fingerprint`
- `protocol_version`
- `supported_methods`
- `agent_capabilities_version`

### Drift Handling

If a later call resolves to a different `RecognizedDeployment`, the turn is drifted.

V1 behavior should be strict:

- mark the turn as `stale` or `drifted`
- stop automatic continuation
- surface restart options in the UI

V1 should not automatically continue on a different runtime identity once planning and capability routing have already been established.

## Logical Workspace

### Definition

`Workspace` in V1 is a special conversation-owned concept, not a general execution-infrastructure object and not a hard sandbox boundary.

Each conversation has one persistent logical workspace.

Properties:

- owned by the conversation
- persistent for the life of the conversation
- lazily initialized
- default file landing zone
- not a restriction on where the agent may operate

### Lifecycle

Workspace lifecycle is persistent:

- create lazily on first real main-lane user message
- keep for the lifetime of the conversation
- clean up only on archive/delete or explicit future reset functionality

The lazy init hook should be:

- `on_lane_first_user_message` for the main lane

This avoids creating empty directories for conversations that never start.

### Default Agent Materialization

For the default local agent, the logical workspace should materialize as a real host directory.

Recommended behavior:

- allocate a conversation-specific host directory
- mount that directory into the default agent container when managed locally
- use it as the default working directory for the agent runtime

This mirrors the OpenClaw-style proven pattern while keeping the broader Cybros model more abstract.

### External Agents

For external agents:

- the logical workspace may exist only as a Cybros-side concept
- Cybros does not require that the agent expose a real local directory
- the agent may decide whether and how to consume workspace information

## Attachments And Upload Transfer

### Source Of Truth

Uploaded files should first land in Active Storage.

Reasons:

- web preview and download already need that storage path
- Cybros should own canonical attachment persistence
- agent-side upload and workspace transfer should derive from that source, not replace it

### Attachment Manifest

Each conversation should maintain an ordered attachment manifest.

Manifest entries should include:

- stable order within the relevant user message context
- original filename
- content type
- byte size
- digest
- owning conversation
- source message reference

The manifest order is important for prompt interpretation, especially when users refer to "the first screenshot" or similar relative descriptions.

### Upload Capability Gate

Agents must declare an `upload` capability if they are expected to consume uploaded files.

If a user sends attachments to an agent that does not support upload:

- reject that message
- do not silently degrade to metadata-only behavior

This avoids false success where the user believes the agent can see the file content when it cannot.

### Transfer Task

Attachment transfer from Cybros to the agent should happen through an explicit transfer task.

Behavior:

- Cybros stores the file in Active Storage
- Cybros verifies the current agent supports upload
- during turn startup or attachment-preparation flow, Cybros creates a transfer task
- the transfer task moves the attachment into agent-consumable form

### Transfer Protocol

V1 should not ship raw attachment bytes over JSON-RPC.

The transfer protocol should be:

- capability name: `upload`
- agent RPC method: `attachments.import`
- payload: normalized attachment descriptors plus signed download URLs

Each descriptor should include:

- stable attachment id
- filename
- content type
- byte size
- digest
- signed download URL
- optional conversation/workspace descriptor metadata

The agent then imports the attachment by fetching the content from the provided URL and returns agent-owned references.

This keeps the protocol simple and avoids embedding binary payloads in the RPC channel.

For the default local agent:

- transfer means materializing the file into the conversation workspace
- the implementation may optimize locally instead of round-tripping through HTTP fetch, but the semantic contract should still match `attachments.import`

For external agents:

- transfer means invoking `attachments.import`
- Cybros records whatever remote reference the agent returns

### Prompt Injection

Prompts should always receive an ordered attachment manifest.

For example:

- `Attachment 1: screenshot-error.png (image/png)`
- `Attachment 2: logs.txt (text/plain)`

Rules:

- keep numbering stable
- include filenames and media types
- feed image attachments to multimodal models as actual image inputs when supported
- do not inline full non-image document contents by default
- let the agent or tools read non-image contents through transfer references or explicit file-reading tools

## Lane And Branch Semantics

### Lanes Inside One Conversation

Lanes remain scheduling branches inside a single conversation.

Within one conversation:

- lanes share the same `Agent`
- lanes share the same logical workspace
- lanes share the same attachment universe

This keeps the conversation runtime simple and lets the DAG engine express concurrency without introducing per-lane file environments in V1.

### New Conversation Branching

When a user branches into a new conversation:

- the new conversation inherits the chosen `Agent` by default
- the new conversation gets a new logical workspace
- workspace contents are not automatically copied in V1
- attachments may reuse the same Active Storage blobs but must create new conversation-local references

This yields strong isolation between conversations while keeping intra-conversation DAG branching lightweight.

## Statistics

Statistics should attach to `RecognizedDeployment` as a runtime dimension.

However, historical integrity must not depend on the continued existence of the dimension row.

Therefore:

- stats facts should persist `recognized_deployment_key`
- stats facts may additionally keep a nullable `recognized_deployment_id`
- aggregation should still work even if the recognized deployment record is retired or purged

This supports:

- per-runtime identity debugging
- per-runtime reliability dashboards
- safe runtime-dimension cleanup

## Failure Modes

V1 should explicitly recognize these failure classes:

- handshake failure
- incompatible metadata
- attachment transfer failure
- runtime drift

Recommended handling:

- handshake failure
  - fail the turn before execution begins
- incompatible metadata
  - mark the agent unavailable for that turn
- attachment transfer failure
  - keep the attachment in Active Storage
  - fail and allow retry
- runtime drift
  - mark the turn drifted/stale
  - require restart rather than continuing automatically

## Migration Direction

The current codebase already stores deployment fingerprints, activation timestamps, and capability snapshots on turn-level runtime records.

V1 cutover should move directly to:

- public `Agent`
- runtime `RecognizedDeployment`
- conversation-owned logical workspace

Existing `AgentProgram`, `AgentDeployment`, `ExecutionLocation`, `Workspace`, and `ExecutionTarget` structures should be treated as removal targets, not long-lived compatibility layers.

## Final Decisions

- `Conversation` binds to `Agent`
- `Turn`/`ConversationRun` binds to `RecognizedDeployment`
- `RecognizedDeployment` is trust-on-observation, not attestation
- `RecognizedDeployment` must be deduplicated and safely deletable
- execution capacity policy is configured on `Agent`
- each conversation owns one persistent logical workspace
- uploaded files land in Active Storage first
- agents must advertise `upload` capability to receive attachments
- attachment delivery uses explicit transfer tasks and `attachments.import` descriptors with signed URLs
- lanes share a conversation workspace
- new conversations get new workspaces
- the dashboard launches new conversations from explicit `Agent` actions rather than a generic `New chat` button
- agent switching inside a conversation is not supported in V1
- agent upgrades affect future turns only; historical turns stay pinned to their captured `RecognizedDeployment`
- runtime drift invalidates the current turn rather than silently continuing
