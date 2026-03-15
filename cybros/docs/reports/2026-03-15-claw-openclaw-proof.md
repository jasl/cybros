# Claw OpenClaw Proof Report

Date: 2026-03-15

## Environment

- Environment time: 2026-03-14T23:44:37Z initial proof start; supplemental runtime-hook proof captured on 2026-03-14T23:56Z
- Provider/model: `codex_subscription/gpt-5.4`
- Main proof conversation id: `019ceebc-cd21-765e-a539-7f76aaac9867`
- Main chat lane id: `019ceebc-cd2e-7ecf-80d8-8fa4b377c85f`
- Main branch conversation id: `019ceebd-e318-7b68-8776-bdf546274937`
- Main branch lane id: `019ceebd-e31c-7c04-97d2-5632b2454a06`
- Web backend exercised in development: `duckduckgo_html`
- Permission mode: `full_access`

Supplemental runtime-hook evidence:

- Supplemental branch conversation id: `019ceec7-d39f-716a-9085-d3d21f9612f9`
- Supplemental branch lane id: `019ceec7-d3a7-70b0-aee9-999f6243e4de`
- Temporary development-only catalog overlay used only for runtime-hook proof:
  - model: `codex_subscription/gpt-5.4`
  - temporary soft limit: `context_soft_limit_tokens=11000`
  - purpose: force a deterministic `on_context_pressure` invocation against the real Codex provider
  - note: the overlay was not part of the shipped code and was removed after evidence capture

## Result

All user-visible proof steps passed in a real development conversation using the configured Codex subscription.

Accepted proof outcome:

- coding loop passed
- memory write/recall passed
- branch recall passed
- web search/fetch passed
- subagent delegation passed
- silent finalization passed with no visible `NO_REPLY`
- DAG-owned `on_context_pressure` task injection was additionally proven in a supplemental real runtime turn

No proof step relied on a hidden `claw`-local scheduler, transcript loop, subagent runner, or silent reply bypass.

## Step 0: Smoke

Prompt:

```text
Reply with READY, identify the tool-visible workspace root you can access, and do not use any tools.
```

Evidence:

- Turn id: `019ceebc-cfa1-70b6-965e-7674bfcd952c`
- Assistant reply: `READY`
- Reported workspace root: `/tmp/cybros-dev-agents/conversations/conversation-019ceebc-cd21-765e-a539-7f76aaac9867`

Reference parity:

- matched
- intentional divergence: none

## Step 1: Coding Loop

Prompt:

```text
Proof step 1, coding loop. Work only inside the tool-visible conversation workspace.
1) Run `pwd && find . -maxdepth 3 -type f | sort`.
2) Create `tmp/proof-note.txt` containing exactly `one`.
3) Read `tmp/proof-note.txt` back and report its current content.
4) Use `apply_patch` to change it so it contains two lines: `one` and `two`.
5) Run `wc -l tmp/proof-note.txt`.
6) Reply with the workspace root, files found, current content, final content, and what the command output means.
```

Evidence:

- Turn id: `019ceebc-f0b0-73a3-b9c2-ef275318f045`
- Tool calls:
  - `exec` task `019ceebd-26be-7c4d-90de-09b91dd7a9f8`
  - `write` task `019ceebd-4224-79af-abda-6ee3e94ca64f`
  - `read` task `019ceebd-5120-7ecf-92ae-4433ca9b0846`
  - `apply_patch` task `019ceebd-5d69-7cd8-9338-a2618a53038d`
  - `read` task `019ceebd-6b64-721e-b1d2-f5f05b5cc879`
  - `exec` task `019ceebd-7588-7f4a-befc-f0fddedc970d`
- Final assistant reply reported:
  - workspace root
  - file readback `one`
  - final content `one` / `two`
  - `wc -l` meaning `2 tmp/proof-note.txt`

Reference parity:

- matched
- intentional divergence: none

## Step 2: Memory Store

Prompt:

```text
Proof step 2, memory store. Use memory_store to save this durable fact exactly: verification animal = otter; preferred proof suffix = amber. Reply briefly once stored.
```

Evidence:

- Turn id: `019ceebd-8f00-734f-a76e-f7123bfc3b33`
- Tool call: `memory_store` task `019ceebd-a4e1-764e-8dce-3da5dd4d6db8`
- Activity preview stored the exact document body
- Final assistant reply: `Stored.`

Reference parity:

- matched with intentional divergence
- divergence: Cybros stored through the conversation-owned memory document callback path, not a workspace memory file

## Step 3: Memory Recall

Prompt:

```text
Proof step 3, memory recall. Use memory_search or memory_get to answer: what verification animal and preferred proof suffix were stored?
```

Evidence:

- Turn id: `019ceebd-af45-7cad-a1ad-fac146e37cdd`
- Tool calls:
  - `memory_search` task `019ceebd-c3c1-7a34-9335-5818116d1c28`
  - `memory_get` task `019ceebd-d5e0-7152-8d70-d6e2628ef3c9`
- Final assistant reply:
  - `Verification animal: otter`
  - `Preferred proof suffix: amber`

Reference parity:

- matched with intentional divergence
- divergence: search/get were backed by the conversation memory kernel service rather than workspace memory files

## Step 4: Branch Recall

Prompt:

```text
Proof step 4, branch recall. Use durable memory to answer: what verification animal and preferred proof suffix were stored in the parent conversation?
```

Evidence:

- Branch conversation id: `019ceebd-e318-7b68-8776-bdf546274937`
- Turn id: `019ceebd-e374-71b6-8ed3-b1e1d7096c23`
- Tool call: `memory_get` task `019ceebd-fca7-73a5-bd4b-30aca2b3516a`
- Final assistant reply repeated the parent-stored values

Reference parity:

- matched with intentional divergence
- divergence: the shared durable memory is the Cybros conversation-owned memory document

## Step 5: Web Search

Prompt:

```text
Proof step 5, web search. Use web_search to find the OpenAI Responses API reference page. Reply with the single best result title and URL.
```

Evidence:

- Turn id: `019ceebe-07ee-7d5e-ba47-e83b43505152`
- Tool call: `web_search` task `019ceebe-1b39-72f9-8c1a-a1f0c5672734`
- Backend recorded in activity preview: `duckduckgo_html`
- Final assistant reply:
  - `Responses Overview | OpenAI API Reference`
  - `https://developers.openai.com/api/reference/responses/overview`

Reference parity:

- matched with intentional divergence
- divergence: development proof used the single enabled backend `duckduckgo_html`

## Step 6: Web Fetch

Prompt:

```text
Proof step 6, web fetch. Use web_fetch on the OpenAI Responses API reference page you just found and reply with the fetched page title plus one short sentence on whether it documents creating responses.
```

Evidence:

- Turn id: `019ceebe-2fe9-7581-b0bd-f3b745263656`
- Tool call: `web_fetch` task `019ceebe-4517-7b45-ac1c-eaa65b1efa9c`
- Final assistant reply:
  - title `Responses Overview | OpenAI API Reference`
  - statement that the page documents creating responses

Reference parity:

- matched with intentional divergence
- divergence: fetch path is Cybros' current development-ready parser/backend set

## Step 7: Subagent

Prompt:

```text
Proof step 7, delegated work. Use a delegated subagent if available.
Ask it this exact question and wait for the result:

Given this exact parent-verified file content from `tmp/proof-note.txt`:
one
two

Does the content contain a line exactly equal to `two`?

Then summarize the delegated result in the parent.
```

Evidence:

- Turn id: `019ceebe-53f5-7aaf-945d-60588c32b2c6`
- Parent tool calls:
  - `subagent_run` task `019ceebe-70ec-7ed9-81d7-a5f8bfdafd8b`
  - `subagent_wait` task `019ceebe-81f2-7476-bf3a-60243ce9d206`
- Subagent id: `019ceebe-71bd-76e1-8718-d7d04bbd8259`
- Subagent conversation id: `019ceebe-71c4-7db2-aa89-0506565d566d`
- Subagent final output: `Yes.`
- Parent final assistant reply summarized the delegated result
- Minimal delegated prompt behavior was confirmed by the subagent context-cost snapshot:
  - `limit_turns=1`
  - only `base_system_prompt` and `safety` sections were injected
  - no tool schema beyond the empty baseline

Reference parity:

- matched with intentional divergence
- divergence: canonical subagent lifecycle remained DAG/kernel-owned rather than `claw`-local

## Step 8A: Silent Finalization In The Main Proof Conversation

Prompt:

```text
Proof step 8, silent flush. This turn intentionally adds context pressure.
If the runtime only needs to flush memory and compact context with no user-visible reply, respond exactly with NO_REPLY after doing that work.
```

Evidence:

- Turn id: `019ceebf-9c19-77df-841b-8a7a91a3c6c1`
- Visible assistant messages in the projected turn: none
- Tool call:
  - `memory_store` task `019ceebf-cdab-7c46-9712-8ca3786b0b73`
- Agent runtime nodes:
  - `019ceebf-9c4f-7733-93b3-796276f907f3` finished with `stop_reason=tool_use` and empty content
  - `019ceebf-cda0-70d9-a838-c72340cecea8` finished with `stop_reason=end_turn`, empty content, and `silent_finalization=true`
- Hook evidence:
  - `before_finalize_output` invocation `conversation_run:019ceebf-9da9-7a4a-9bde-b0f3247b9286:before_finalize_output:019ceebf-cda0-70d9-a838-c72340cecea8`
  - returned action: `{ type: "finish_silently", reason: "silent_reply" }`

Reference parity:

- matched with intentional divergence
- divergence: Cybros persisted an explicit DAG/runtime `finish_silently` outcome instead of relying only on hidden delivery suppression

## Step 8B: DAG-Owned `on_context_pressure` Task Injection Proof

Why a supplemental turn was needed:

- Step 8A proved silent finalization and no visible `NO_REPLY` leakage.
- To separately prove that pre-compaction memory flush travels through normal DAG task/activity surfaces, a temporary development-only soft-limit override was applied against the real Codex provider.
- Because the proof conversation's durable memory had already accumulated prior flush summaries, forcing the soft limit low enough to trigger `on_context_pressure` caused repeated advisory compaction cycles.
- The proof was intentionally stopped after the first verified DAG cycle, and proof-created live nodes were cleaned with `proof_cleanup_interrupted`.

Supplemental proof conversation:

- Conversation id: `019ceec7-d39f-716a-9085-d3d21f9612f9`
- Lane id: `019ceec7-d3a7-70b0-aee9-999f6243e4de`
- Turn id: `019ceec8-5383-7bad-a360-3e9cd1b09b34`

Prompt:

```text
Proof step 8d, runtime context-pressure flush verification.
This turn is for runtime verification only.
If the system only needs compaction and durable-memory flushing with no user-visible reply, reply exactly with NO_REPLY after that housekeeping.
Do not do unrelated work.
```

First-cycle evidence:

- First stopped agent node content:
  - `Handling context pressure | State: soft_limit_reached | Action: advise_compact`
- `on_context_pressure` invocation:
  - `conversation_run:019ceec8-54cf-7f1a-a3d8-ab671e74229b:on_context_pressure:019ceec8-53b8-7ee7-90f2-ccf2f0ad1e86`
- Hook result actions:
  - `set_step_status`
  - `create_task logical_tool_name=memory_store placement=prepend`
  - `create_task logical_tool_name=compact_context placement=prepend`
- Materialized DAG task nodes:
  - `memory_store` task `019ceec8-5b3b-74ed-bcd2-5d11a19eb3b1`, `generated_by=programmable_agent_hook`
  - `compact_context` task `019ceec8-5b5f-7428-b138-eda824ba3c4f`, `generated_by=programmable_agent_hook`
- `compact_context` activity preview:
  - `Context already fits within the current prompt budget.`

What this proves:

- the runtime invoked `on_context_pressure`
- `claw` responded with hook actions, not a hidden internal loop
- Cybros materialized those actions as ordinary DAG task nodes
- the flush path used the normal `tool.execute` / task projection surface
- the compaction task ran through `kernel://compact_context`, not a `claw`-local emulation

Reference parity:

- matched with intentional divergence
- divergence: the proof used a temporary development-only soft-limit override to trigger the runtime hook deterministically

## No Shadow Loop Check

Evidence that the implementation respected the no-shadow-loop rule:

1. Tool execution went through ordinary DAG task nodes with `implementation_ref` values such as `claw:exec`, `claw:memory_store`, `claw:web_search`, and `kernel://compact_context`.
2. Delegation used the kernel subagent path (`kernel://subagent_run`, `kernel://subagent_wait`) and produced a separate subagent conversation.
3. Silent completion used the DAG-owned `before_finalize_output -> finish_silently` surface.
4. Context-pressure handling produced ordinary prepended DAG task nodes and did not invent a private `claw` scheduler.

## Completion Gate

Completion gate status:

- all user-facing proof steps passed: yes
- proof report written: yes
- divergences documented: yes
- no required capability left unproven: yes
- hidden `claw`-local loop dependency found: no
