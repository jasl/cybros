# Programmable Agent Rebaseline Repair Handoff

Use this prompt to start a fresh repair session from the existing audit without re-doing the audit itself.

## Recommended Skills

- `writing-plans`: turn the audit into a concrete repair plan before touching code
- `dispatching-parallel-agents`: split independent fix domains into parallel batches
- `test-driven-development`: required for every code fix
- `systematic-debugging`: required for any failing test, flaky E2E, or unexpected runtime behavior
- `requesting-code-review`: required after each repair batch
- `receiving-code-review`: required when acting on non-trivial review feedback
- `verification-before-completion`: required before any “fixed/passing/done” claim
- `playwright-interactive`: required for any touched browser/operator surface

External skills searched during audit:

- `ag0os/rails-dev-plugin@ruby refactoring expert`
- `dchuk/rails_ai_agents@tdd-cycle`
- `pproenca/dot-skills@rails-testing`

Current built-in skills already cover the needed workflow, so no extra install is required to start.

## Prompt

```text
Continue the programmable-agent rebaseline repair from the existing audit. This is a repair session, not a re-audit and not brainstorming.

Workspace: /Users/jasl/Workspaces/Cybros/cybros

Primary sources of truth:
- /Users/jasl/Workspaces/Cybros/cybros/cybros/docs/audits/programmable-agent-rebaseline-audit.md
- relevant plans under /Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans
- product docs under /Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product only as fallback interpretation

Required skills and order:
1. using-superpowers
2. writing-plans
3. dispatching-parallel-agents
4. test-driven-development for every fix
5. systematic-debugging for any failure or unexpected behavior
6. requesting-code-review after every repair batch
7. receiving-code-review when applying reviewer feedback
8. playwright-interactive for any touched browser/operator surface
9. verification-before-completion before any completion claim

Do not re-open product semantics that are already explicit in plans/docs unless a contradiction is proven by fresh evidence.

Start with:
1. confirm current branch and worktree status
2. read the audit doc and extract only the fixable findings
3. explicitly exclude PA-006, PA-011, and PA-012 from implementation in this session; keep them as discussion items
4. write a repair plan to docs/plans with small TDD-first tasks and verification commands
5. execute the plan in batches, using parallel agents only for independent domains

Repair priority for this session:
- First batch: PA-004, PA-005, PA-008, PA-010, PA-013
- Second batch if first batch is stable: PA-001, PA-003, PA-007, PA-009
- Do not silently drop PA-002; either implement it in a dedicated later batch or explicitly leave it open with a reason

Implementation rules:
- no production code without a failing test first
- no “fixed” claim without fresh verification evidence
- after each batch: run targeted tests, then request code review, fix review findings, then rerun verification
- if browser/operator surfaces are touched, run browser-backed verification again
- keep the audit doc updated: remove or mark items you fully closed, but do not delete unresolved discussion items

Expected final output of the repair session:
- which PA items were closed
- which remain open
- exact verification commands run and their results
- current git status
- any residual risk
```
