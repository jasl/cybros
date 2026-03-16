# Cybros / Claw Kernel Program Architecture Audit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a code-backed architecture audit package that assigns ownership between `cybros` and `claw`, identifies migration and deletion candidates, and recommends both a phased refactor path and a big-bang cutover option.

**Architecture:** The work is documentation-led but code-backed. Treat `cybros` as the kernel/runtime and `claw` as the loaded program. Use current runtime code, recent design docs, targeted tests, and documentation drift checks to build an ownership matrix, migration candidate ledger, findings ledger, deletion list, and phase plan. Do not refactor production code during this audit pass; first produce the decision package that determines what should be changed.

**Tech Stack:** Ruby on Rails monorepo, Markdown docs under `cybros/docs`, `rg`, git, targeted Rails and `claw` tests for evidence validation

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros`

**Design Source:** `cybros/docs/plans/2026-03-17-cybros-claw-kernel-program-audit-design.md`

---

### Task 1: Create The Audit Report Skeleton

**Files:**
- Create: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Reference: `cybros/docs/plans/2026-03-17-cybros-claw-kernel-program-audit-design.md`

**Step 1: Create the report file**

Add these empty sections in order:

- Executive Summary
- Scope And Evidence
- Kernel / Program Ownership Matrix
- Migration Candidate Ledger
- Findings Ledger
- Delete Now List
- Documentation Drift
- Phase Plan
- Big-bang Cutover Appendix

**Step 2: Verify the file exists**

Run: `sed -n '1,200p' cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`

Expected: the new report exists with the exact section headers above.

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: scaffold kernel program audit report"
```

### Task 2: Build The Evidence Inventory

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Reference: `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`
- Reference: `cybros/docs/plans/2026-03-16-bundled-claw-external-runtime-design.md`
- Reference: `cybros/docs/reports/2026-03-15-claw-openclaw-parity-report.md`

**Step 1: Gather the design and report inputs**

Run:

- `sed -n '1,220p' cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`
- `sed -n '1,220p' cybros/docs/plans/2026-03-16-bundled-claw-external-runtime-design.md`
- `sed -n '1,220p' cybros/docs/reports/2026-03-15-claw-openclaw-parity-report.md`

Expected: the inputs clearly state the current runtime split and any intentional divergences.

**Step 2: Write the Scope And Evidence section**

Record:

- which docs define the accepted boundary today
- which code areas will be treated as primary evidence
- which assumptions remain provisional until code inspection confirms them

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: record kernel program audit evidence set"
```

### Task 3: Fill The Ownership Matrix From Live Code

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Reference: `cybros/app/services/agent_rpc/`
- Reference: `cybros/lib/agent_core/`
- Reference: `agents/claw/lib/cybros/agents/claw/`
- Reference: `agents/claw/agent.yml`

**Step 1: Inspect the kernel and program surfaces**

Run:

- `rg -n "compact_context|subagent|approval|finish_silently|tool.execute|before_agent_step|on_context_pressure|memory_" cybros/app cybros/lib agents/claw/lib agents/claw/agent.yml`
- `find agents/claw/lib/cybros/agents/claw -maxdepth 3 -type f | sort`
- `find cybros/app/services/agent_rpc cybros/lib/agent_core -type f | sort | sed -n '1,240p'`

Expected: enough evidence to map ownership for runtime lifecycle, tools, memory, workspace/bootstrap, approvals, compaction, subagent handling, and prompt assembly.

**Step 2: Populate the Ownership Matrix**

For each major capability, assign one primary owner:

- `cybros`
- `claw`
- `delete/collapse`

If current ownership is mixed, mark it explicitly as architecture debt in the matrix notes.

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: map cybros claw ownership boundaries"
```

### Task 4: Build The Migration Candidate Ledger

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Reference: `cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`
- Reference: `agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`
- Reference: `agents/claw/lib/cybros/agents/claw/hooks/`
- Reference: `agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`

**Step 1: Inspect experiment-heavy surfaces**

Run:

- `sed -n '1,220p' cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`
- `sed -n '1,240p' agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`
- `find agents/claw/lib/cybros/agents/claw/hooks -type f | sort | xargs -I{} sed -n '1,220p' {}`
- `sed -n '1,220p' agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`

Expected: a concrete list of capabilities that were allowed to sit in `claw` for experimentation.

**Step 2: Classify each candidate**

For every candidate, record:

- current owner
- reason it was previously left in `claw`
- recommendation: `stay`, `move`, or `delete/collapse`
- rationale for that recommendation
- constraints required if it stays in `claw`

`memory` must be classified explicitly, not implicitly.

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: classify claw migration candidates"
```

### Task 5: Identify Delete-Now Targets And Compatibility Debt

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Reference: `cybros/docs/product/`
- Reference: `cybros/docs/agent_core/`
- Reference: `cybros/docs/dag/`
- Reference: `agents/claw/`

**Step 1: Scan for stale or redundant surfaces**

Run:

- `find agents/claw -path '*/tmp' -prune -o -path '*/vendor' -prune -o -type f | sort | sed -n '1,240p'`
- `find cybros/docs/product cybros/docs/agent_core cybros/docs/dag -type f | sort`
- `rg -n "ExecutionTarget|ExecutionLocation|AgentDeployment|AgentProgram|managed-local|in-process host|logical workspace" cybros agents/claw cybros/docs`

Expected: a list of obsolete concepts, compatibility wrappers, stale docs, and runtime leftovers that should be deleted instead of preserved.

**Step 2: Fill the Delete Now List and Findings Ledger**

Each delete/collapse finding should include:

- evidence
- why it is obsolete
- whether it is code, config, runtime artifact, or doc
- which later task would become simpler once it is removed

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: record delete now targets for kernel program audit"
```

### Task 6: Validate High-Risk Judgments With Targeted Commands

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`

**Step 1: Run targeted verification**

Run:

- `cd /Users/jasl/Workspaces/Cybros/cybros/agents/claw && bin/test`
- `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/agent_rpc test/lib/agent_core/dag`

Expected: commands complete successfully, or any failures are documented as evidence against the current architecture.

**Step 2: Update the report with verification notes**

For each command, record:

- command run
- pass/fail result
- whether it confirms or challenges a major audit conclusion

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: attach verification evidence to kernel program audit"
```

### Task 7: Produce The Phase Plan And Big-Bang Appendix

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`

**Step 1: Write the Phase Plan**

Define:

- `Phase 1 Must-fix`
- `Strong migration candidates`
- `Keep in claw for now, but constrain`
- `Delete now`

Every listed item should point back to evidence already captured in the report.

**Step 2: Write the big-bang appendix**

Describe:

- the minimum cut line for a one-shot refactor
- the highest-risk dependency chain
- what should be removed immediately in a destructive cutover

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: finish kernel program audit execution package"
```

### Task 8: Final Sanity Check And Handoff

**Files:**
- Modify: `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`

**Step 1: Check formatting and unresolved markers**

Run:

- `rg -n "TODO|TBD|FIXME|TO_REPLACE" cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- `git diff --check`

Expected: no unresolved markers in the report and no whitespace errors in the repo diff.

**Step 2: Write the final handoff note at the top or bottom of the report**

The handoff note should tell the next implementer:

- whether to start with the phased path or the big-bang path
- which migration candidates need explicit user selection before coding
- which delete-now items are safe immediately

**Step 3: Commit**

```bash
git add cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md
git commit -m "docs: hand off kernel program architecture audit"
```
