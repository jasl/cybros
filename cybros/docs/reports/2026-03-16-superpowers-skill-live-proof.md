# Superpowers Skill Live Proof

- Date: 2026-03-16
- Model ref: openrouter/openai-gpt-5.4
- Source repo: https://github.com/obra/superpowers
- Source raw skill: https://raw.githubusercontent.com/obra/superpowers/main/skills/verification-before-completion/SKILL.md
- Workspace root: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-7822-89b3lx`

## Install Conversation

- Conversation id: `019cf40d-5287-7674-978f-6ee12b275471`
- Protected write approved by: `live-acceptance:harness`
- Approved at: `2026-03-16T00:31:13Z`
- Task names: web_fetch, exec, write, read
- Installed skill path: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-7822-89b3lx/claw-019ced08-d411-721d-afbd-805fad46840b/skills/verification-before-completion/SKILL.md`
- Next-top-level-turn description: Use when about to claim work is complete, fixed, or passing, before committing or creating PRs - requires running verification commands and confirming output before making any success claims; evidence before assertions always
- Exact byte match to upstream raw file: false

## Usage Conversation

- Conversation id: `019cf40d-ef31-7b25-b5fb-ad0aa9e6f73e`
- Task names: glob, search, write, read
- Proof file: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-7822-89b3lx/claw-019ced08-d411-721d-afbd-805fad46840b/conversations/019cf40d-ef31-7b25-b5fb-ad0aa9e6f73e/artifacts/superpowers-skill-proof.txt`
- Proof file content: `"SUPERPOWERS_SKILL_PROOF_11b80a0b\n"`
- Final reply: `VERIFIED: SUPERPOWERS_SKILL_PROOF_11b80a0b`

## Source Diff Preview

```diff
--- /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/superpowers-source20260316-9676-k0y585	2026-03-16 08:32:56
+++ /var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/superpowers-installed20260316-9676-1w0o7a	2026-03-16 08:32:56
@@ -77,19 +77,19 @@

 **Tests:**
 ```
-✅ [Run test command] [See: 34/34 pass] "All tests pass"
+✅ [Run test command] → [See: 34/34 pass] → "All tests pass"
 ❌ "Should pass now" / "Looks correct"
 ```

 **Regression tests (TDD Red-Green):**
 ```
-✅ Write → Run (pass) → Revert fix → Run (MUST FAIL) → Restore → Run (pass)
+✅ Write test → Run (pass) → Revert fix → Run (MUST FAIL) → Restore → Run (pass)
 ❌ "I've written a regression test" (without red-green verification)
 ```

 **Build:**
 ```
-✅ [Run build] [See: exit 0] "Build passes"
+✅ [Run build] → [See: exit 0] → "Build passes"
 ❌ "Linter passed" (linter doesn't check compilation)
 ```

@@ -108,32 +108,61 @@
 ## Why This Matters

 From 24 failure memories:
-- your human partner said "I don't believe you" - trust broken
-- Undefined functions shipped - would crash
-- Missing requirements shipped - incomplete features
+- your human partner said "I don't believe you" → trust broken
+- Undefined functions shipped → would crash
+- Missing requirements shipped → incomplete features
 - Time wasted on false completion → redirect → rework
 - Violates: "Honesty is a core value. If you lie, you'll be replaced."

 ## When To Apply

 **ALWAYS before:**
-- ANY variation of success/completion claims
-- ANY expression of satisfaction
-- ANY positive statement about work state
-- Committing, PR creation, task completion
-- Moving to next task
-- Delegating to agents
+- ANY variation of success/completion claim
+- Commit messages implying fix/completion
+- PR descriptions
+- Status updates saying "done", "fixed", "working"
+- Expressing satisfaction with work
+- Handing off to humans/other agents

-**Rule applies to:**
-- Exact phrases
-- Paraphrases and synonyms
-- Implications of success
-- ANY communication suggesting completion/correctness
+**Especially when:**
+- You feel confident
+- Changes seem small
+- You're in a hurry
+- An agent/subprocess did the work
+- You already verified earlier
+- You fixed "just one thing"

-## The Bottom Line
+## The Protocol

-**No shortcuts for verification.**
+### Bad
+```
+Implemented the fix for the parser bug. It should work now.
+```

-Run the command. Read the output. THEN claim the result.
+### Good
+```
+Implemented the fix for the parser bug.
+Verified with: `bin/rails test test/path/to/parser_test.rb`
+Result: 12 runs, 48 assertions, 0 failures, 0 errors
+```

-This is non-negotiable.
+### Bad
+```
+Done! Everything is working perfectly.
+```
+
+### Good
+```
+Made the requested changes.
+Verification pending: I have not yet run the relevant test/build commands.
+```
+
+## Bottom Line
+
+**No evidence = no claim.**
+
+Run verification commands before any completion statement.
+Read results.
+Then speak.
+
+Never reverse this order.
```
