# Agent Root Workspace Proof

- Date: 2026-03-16
- Started at (UTC): 2026-03-16T07:11:36Z
- Finished at (UTC): 2026-03-16T07:18:20Z
- Model ref: openrouter/openai-gpt-5.4
- Environment: development @ Juns-MacBook-Pro-M4-2419.local
- Approval driver: `approve_awaiting_nodes`
- Runs per scenario: 3
- Workspace root base: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260316-86210-92ftpx`

## Scenario outcomes

| Scenario | Run | Status | Approvals | Conversation ids | Note |
| --- | --- | --- | --- | --- | --- |
| Root shared memory 1 PASS 0 019cf57c-68b6-7d80-8aca-2b3716c19ef2, 019cf57c-6a25-7a65-ae86-2541277cd166 token=ROOT_SHARED_TOKEN_1_4aef7d6a |
| Root shared memory 2 PASS 0 019cf57c-b084-75bb-a8f6-cc0c220a5dae, 019cf57c-b18e-7899-840e-e60d98c0cc9d token=ROOT_SHARED_TOKEN_2_384b6da5 |
| Root shared memory 3 PASS 0 019cf57c-ec23-7eff-b487-bf8b39235a20, 019cf57c-ed1b-7695-b984-447da78dcb50 token=ROOT_SHARED_TOKEN_3_18b6ba92 |
| Conversation isolation 1 PASS 0 019cf57d-2bfe-7ae5-ad56-2091a68cab57, 019cf57d-2cf4-709e-a4d5-f17b065dea25 isolated token=CONVERSATION_ONLY_TOKEN_1_9dffb504 |
| Conversation isolation 2 PASS 0 019cf57d-62b4-74b1-876b-53e3f3f97eef, 019cf57d-63b1-7180-8b46-b8efe8759ea5 isolated token=CONVERSATION_ONLY_TOKEN_2_0c8a32b5 |
| Conversation isolation 3 PASS 0 019cf57d-9cda-793b-9817-ffa702eee537, 019cf57d-9de0-7ee3-b3d3-3f0d55b8f7b4 isolated token=CONVERSATION_ONLY_TOKEN_3_750aaa67 |
| Lane-local memory isolation 1 PASS 0 019cf57d-dd90-7877-b35f-0386b4527276, 019cf57d-de87-7a9b-abaf-74dab27be48e lane token=LANE_ONLY_TOKEN_1_9db21ade |
| Lane-local memory isolation 2 PASS 0 019cf57e-1735-741e-947f-1501c9abe8d2, 019cf57e-1863-7572-9bf4-7390e13cf770 lane token=LANE_ONLY_TOKEN_2_29109ae8 |
| Lane-local memory isolation 3 PASS 0 019cf57e-53dc-76c5-af22-c9fcafb76b3d, 019cf57e-54e3-789f-b8c6-d0b7e3c1018d lane token=LANE_ONLY_TOKEN_3_187ee73a |
| Branch snapshot inheritance 1 PASS 0 019cf57e-8dd6-7850-8d03-43426fa481c4, 019cf57e-af65-71ea-b953-5302ceabd9d1 branch token=BRANCH_SNAPSHOT_TOKEN_1_ca6e454a |
| Branch snapshot inheritance 2 PASS 0 019cf57e-cccb-7a4b-a6f3-87e3c9586122, 019cf57e-f090-7170-872c-a970d232cfc3 branch token=BRANCH_SNAPSHOT_TOKEN_2_d53bb45f |
| Branch snapshot inheritance 3 PASS 0 019cf57f-0b65-7164-b135-f36b625c544d, 019cf57f-32c3-75e7-b9bb-1bb576c7d78a branch token=BRANCH_SNAPSHOT_TOKEN_3_70abfe36 |
| Directory complexity tolerance 1 PASS 0 019cf57f-482e-7aaf-8652-678ce72e0b43 artifact token=DIRECTORY_COMPLEXITY_TOKEN_1_f96f6819 |
| Directory complexity tolerance 2 PASS 0 019cf57f-60d5-78bb-b9cf-83b860ebcf32 artifact token=DIRECTORY_COMPLEXITY_TOKEN_2_75def892 |
| Directory complexity tolerance 3 PASS 0 019cf57f-7649-7673-91c5-174205563717 artifact token=DIRECTORY_COMPLEXITY_TOKEN_3_d4ede82e |
| Compaction durability 1 PASS 0 019cf57f-90fd-7d89-b4e6-8b40d711e6c4, 019cf57f-95bd-71a1-b47a-7aee3484f4b4, 019cf57f-9a59-72b8-93d8-4c41b2b5b469, 019cf57f-9fa0-76a1-8d39-6d32479fe750, 019cf57f-a500-7768-b800-2da7c9a0e6c4, 019cf57f-aad1-7be0-96eb-97f6023e4fe9, 019cf57f-b0f9-7c7c-99bd-681b141434f0 summary_seq=10 |
| Compaction durability 2 PASS 0 019cf57f-d453-7dbc-b2ed-90200c14063c, 019cf57f-d8e0-75c9-968b-b1d031266574, 019cf57f-ddad-78f9-814a-da0069cad01d, 019cf57f-e357-735e-8bb4-0c340938dd8b, 019cf57f-e89d-7cfb-ac09-908ef2747d4c, 019cf57f-ee78-7900-8ef9-3062009f5e32, 019cf57f-f4a2-7667-a88c-96293a048603 summary_seq=10 |
| Compaction durability 3 PASS 0 019cf580-11c8-7851-b14e-95eccfeedd93, 019cf580-1705-729d-b00d-f1e21812b4c2, 019cf580-1c21-72f0-a462-8f1c256f7e77, 019cf580-2159-7139-b181-9a1bdb4ba989, 019cf580-2722-7025-be33-46fb301bb2f4, 019cf580-2cfe-7e6f-9ae4-8611ffc5dbc7, 019cf580-3347-7e10-85ff-0bcdd51bdafa summary_seq=10 |
| Self-mutate SOUL.md 1 PASS 1 019cf580-501e-7d8e-b7e6-69a2d422ae84 soul token=SOUL_MUTATION_TOKEN_1_b91ef90e |
| Self-mutate SOUL.md 2 PASS 1 019cf580-77a3-74ac-9441-311ceeec92f6 soul token=SOUL_MUTATION_TOKEN_2_3ee4bf48 |
| Self-mutate SOUL.md 3 PASS 1 019cf580-9cac-7c52-8609-2e065f904d77 soul token=SOUL_MUTATION_TOKEN_3_a19e9c0f |
| Self-mutate USER.md 1 PASS 1 019cf580-c60c-7fd0-a198-751954ee21de user token=USER_MUTATION_TOKEN_1_651330c3 |
| Self-mutate USER.md 2 PASS 1 019cf580-f370-7709-b0bb-fde1a7d5479c user token=USER_MUTATION_TOKEN_2_d8a8918f |
| Self-mutate USER.md 3 PASS 1 019cf581-1725-7cdf-b25b-bde886352baf user token=USER_MUTATION_TOKEN_3_50c34cb1 |
| Create agent-local skill 1 PASS 1 019cf581-3f3f-7410-8633-5a11e586e933 skill=live-acceptance-1-c3d7d8 |
| Create agent-local skill 2 PASS 1 019cf581-5b41-7be4-8039-957815ce9e05 skill=live-acceptance-2-b13850 |
| Create agent-local skill 3 PASS 1 019cf581-7a9b-7847-9ff3-fd37eb1ddcd3 skill=live-acceptance-3-be7d6d |
| Modify agent-local skill 1 PASS 1 019cf581-9e90-7033-b18d-286162ea2c3f self-mutate description updated |
| Modify agent-local skill 2 PASS 1 019cf581-c6cd-7ff6-b8da-645d5f5adbfb self-mutate description updated |
| Modify agent-local skill 3 PASS 1 019cf581-f3df-704f-a049-783d95efdee6 self-mutate description updated |
| Deny AGENTS.md mutation 1 PASS 0 019cf582-1922-71f5-9e41-213ebfd2b0d2 AGENTS.md stayed read-only |
| Deny AGENTS.md mutation 2 PASS 0 019cf582-3cb2-7176-a785-2f3f6b23eb8a AGENTS.md stayed read-only |
| Deny AGENTS.md mutation 3 PASS 0 019cf582-5dba-7f17-bd1e-2c2cb14d71f4 AGENTS.md stayed read-only |

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
