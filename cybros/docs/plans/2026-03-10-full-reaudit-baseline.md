# Full Reaudit Baseline

**Status:** active baseline for the next full-programmable-agent re-audit after the `codex/programmable-agent-rebaseline` repair and acceptance pass.

**Purpose:** prevent a new audit from treating historical audit wording or pre-repair terminology as the current product spec.

## Source Of Truth Order

Use these sources in this order:

1. the newest area-specific plan docs under [`docs/plans`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans)
2. current product docs under [`docs/product`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product) when they do not conflict with newer plans
3. current code and tests for implementation evidence
4. audit docs under [`docs/audits`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/audits) as historical findings and closure records only

If a plan doc and a product doc conflict, treat that as a spec conflict and say so explicitly. Do not let an older audit or repair handoff override either of them.

## Current Semantic Baseline

Use these documents as the primary semantic baseline for the repaired programmable-agent/runtime-governance surface:

- [`docs/plans/2026-03-09-agent-deployment-connection.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-09-agent-deployment-connection.md)
- [`docs/archive/plans/2026-03/2026-03-09-execution-target-discovery-design.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/archive/plans/2026-03/2026-03-09-execution-target-discovery-design.md)
- [`docs/plans/2026-03-09-permission-presets-design.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-09-permission-presets-design.md)
- [`docs/plans/2026-03-09-execution-capacity-and-scheduled-automation.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-09-execution-capacity-and-scheduled-automation.md)
- [`docs/archive/plans/2026-03/2026-03-09-runtime-governance-operator-surfaces.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/archive/plans/2026-03/2026-03-09-runtime-governance-operator-surfaces.md)
- [`docs/product/runtime_governance.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/runtime_governance.md)
- [`docs/product/run_lifecycle.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/run_lifecycle.md)
- [`docs/product/kernel_service_surface.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/kernel_service_surface.md)
- [`docs/product/automation.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/automation.md)

## Historical Docs That Must Not Be Treated As Current Spec

- [`docs/audits/programmable-agent-rebaseline-audit.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/audits/programmable-agent-rebaseline-audit.md)
  It is a repair ledger and evidence log, not the semantic source of truth.
- [`docs/audits/programmable-agent-rebaseline-repair-handoff.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/audits/programmable-agent-rebaseline-repair-handoff.md)
  It is session history only. Its PA scoping and sequencing assumptions are obsolete.

## Known Terminology Drift

These terms are historical aliases and should not be reported as fresh bugs by themselves:

- `execution_quota` means `execution_capacity`
- location or target `quota` means execution-capacity policy or execution-capacity override
- quota wait reason means `RuntimeWait.reason_type == "execution_capacity"`
- quota denial means execution-capacity denial

Current terminology should use `execution_capacity` consistently in findings unless a document or code path still truly exposes the old name.

## Reaudit Preflight Rules

Before writing any finding:

1. build a drift map for any renamed concepts
2. identify which documents are current spec and which are historical
3. separate terminology drift from behavior drift
4. only then start the real audit

The audit must classify each issue as exactly one of:

- implementation bug
- documentation drift
- unresolved spec conflict

Do not file a code bug when the only mismatch is an obsolete term in an old audit or handoff doc.

## Recommended Skills For Audit Quality

These installed skills improve audit quality and should be used deliberately:

- `using-superpowers`
  Always required at turn start.
- `dispatching-parallel-agents`
  Use for independent audit domains so evidence gathering does not serialize.
- `requesting-code-review`
  Use after each major audit batch or before issuing final findings if substantial verification ran.
- `receiving-code-review`
  Use when audit findings from reviewers or subagents conflict.
- `systematic-debugging`
  Use any time a verification command or flaky test produces ambiguous evidence.
- `verification-before-completion`
  Use before claiming the audit is complete or a finding is closed.
- `playwright-interactive`
  Use if browser/operator behavior becomes part of the audit evidence.
- `security-best-practices`
  Use only for a dedicated security slice.
- `web-design-guidelines`
  Use only for a dedicated UI/UX or accessibility slice.

## Suggested New-Chat Prompt

```text
请对 /Users/jasl/Workspaces/Cybros/cybros/cybros 做一轮全审计。

先做 preflight，不要直接开始逐项审计。

审计基线文件：
/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-10-full-reaudit-baseline.md

执行规则：
1. 严格按 baseline 文档中的 source-of-truth 顺序开展工作
2. 先输出 baseline summary，再开始正式审计
3. docs/audits 只作为历史记录，不作为当前语义基线，除非它引用的更高优先级 plans/product docs 也支持同一结论
4. 遇到术语漂移时，先建立 drift map；不要把纯术语差异直接当实现缺陷
5. findings 必须明确分类为：
   - implementation bug
   - documentation drift
   - unresolved spec conflict
6. 如果验证命令出现 flaky 或互相矛盾的证据，先进入调试/复验，不要直接下结论
7. 最终输出时 findings 优先，按严重度排序，并附文件与行号

重点要求：
- 对 programmable-agent、runtime-governance、automation、operator surfaces 做全覆盖复审
- 不要被旧 audit 文档中的历史术语误导，例如 execution_quota 这种旧命名
- 如果 plans 与 product docs 冲突，明确指出冲突，不要擅自站队旧 audit
- 对每个“疑似问题”都说明它是代码问题还是文档问题

建议使用的 skills：
- using-superpowers
- dispatching-parallel-agents
- systematic-debugging
- requesting-code-review
- receiving-code-review
- verification-before-completion
- playwright-interactive（仅当浏览器证据需要时）

最终交付：
1. baseline summary
2. 审计 findings（按严重度）
3. 文档漂移清单
4. 未决 spec conflict 清单
5. 运行过的验证命令和结果
6. residual risk
```
