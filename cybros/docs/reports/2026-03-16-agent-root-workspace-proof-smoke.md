# Agent Root Workspace Proof

- Date: 2026-03-16
- Started at (UTC): 2026-03-16T00:01:25Z
- Finished at (UTC): 2026-03-16T00:03:32Z
- Model ref: openrouter/openai-gpt-5.4
- Environment: development @ Juns-MacBook-Pro-M4-2419.local
- Approval driver: `approve_awaiting_nodes`
- Runs per scenario: 1
- Workspace root base: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260316-35389-ppdjnn`

## Scenario outcomes

| Scenario | Run | Status | Approvals | Conversation ids | Note |
| --- | --- | --- | --- | --- | --- |
| Root shared memory 1 PASS 0 019cf3f2-8fa8-7616-8b9d-e295263482a7, 019cf3f2-90eb-7b48-98ce-5e94b33a8d82 token=ROOT_SHARED_TOKEN_1_4e8d22a7 |
| Conversation isolation 1 PASS 0 019cf3f2-d53d-7b74-8f8e-7371e59c3399, 019cf3f2-d628-74f7-b51e-043db1fe6138 isolated token=CONVERSATION_ONLY_TOKEN_1_40c09432 |
| Lane-local memory isolation 1 PASS 0 019cf3f3-0a1e-751e-af5c-30047ead6d7c, 019cf3f3-0b16-776b-ad2e-7d40d2052bf4 lane token=LANE_ONLY_TOKEN_1_5a9328c3 |
| Branch snapshot inheritance 1 PASS 0 019cf3f3-482c-7332-8331-5ac74614f2d5, 019cf3f3-6bbc-7e8e-9c40-bb5531f919b6 branch token=BRANCH_SNAPSHOT_TOKEN_1_345c5b5b |
| Directory complexity tolerance 1 PASS 0 019cf3f3-80a1-78b1-a4d9-258c7767e29e artifact token=DIRECTORY_COMPLEXITY_TOKEN_1_1c035e71 |
| Compaction durability 1 PASS 0 019cf3f3-9382-79bb-a49c-75ec0ab7f7c6, 019cf3f3-9776-7f37-ad0b-0aab089b484a, 019cf3f3-9bc6-71a8-9772-3a6e9ef38f55, 019cf3f3-a05e-7837-853d-ba019676ef04, 019cf3f3-a50b-7fed-92e5-9de4764b38d0, 019cf3f3-a9e1-781e-89b4-7ec661b1dedb, 019cf3f3-af14-770c-b15a-5dcf64b8784b summary_seq=10 |
| Self-mutate SOUL.md 1 PASS 1 019cf3f3-c942-74e3-a19d-25c032f05d26 soul token=SOUL_MUTATION_TOKEN_1_d5c5cfb8 |
| Self-mutate USER.md 1 PASS 1 019cf3f3-f2b8-7c3f-a235-d05cb3cc0b0d user token=USER_MUTATION_TOKEN_1_bc7b5d93 |
| Create agent-local skill 1 PASS 1 019cf3f4-19b3-74eb-901a-dd3447660256 skill=live-acceptance-1-ccb7a1 |
| Modify agent-local skill 1 PASS 1 019cf3f4-4132-753d-af58-f97ca28ca0cc self-mutate description updated |
| Deny AGENTS.md mutation 1 PASS 0 019cf3f4-6767-7822-a222-faecade6d5d4 AGENTS.md stayed read-only |

## Scenario summary

- Root shared memory: PASS
- Conversation isolation: PASS
- Lane-local memory isolation: PASS
- Branch snapshot inheritance: PASS
- Directory complexity tolerance: PASS
- Compaction durability: PASS
- Self-mutate SOUL.md: PASS
- Self-mutate USER.md: PASS
- Create agent-local skill: PASS
- Modify agent-local skill: PASS
- Deny AGENTS.md mutation: PASS
