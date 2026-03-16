# Superpowers Skill Live Proof (Rerun)

- Date: 2026-03-16
- Finished at (UTC): 2026-03-16T09:21:14Z
- Rails env: development
- Model ref: openrouter/openai-gpt-5.4
- Source repo: https://github.com/obra/superpowers
- Source raw skill: https://raw.githubusercontent.com/obra/superpowers/main/skills/verification-before-completion/SKILL.md
- Workspace root: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-82998-5eeg7k`

## Self Review

- Review result: no new blocker found in the final installer/claw diff after contract and live verification.
- `git diff --check`: clean

## Literal Repo Attempt

- Conversation id: `019cf5f2-74c4-7a73-ae51-09797b7592a4`
- Task names: skills_install
- Approval count: 1
- Result: rejected as expected because repo root is not a single skill package
- Validation code: `cybros.skills_install.invalid_skill_root`
- Final reply: "`skills_install` failed.\n\nResult:\n- `Fetched skill root must contain SKILL.md.`\n\nI used the protected installer path only. The requested exact minimal arguments aren’t sufficient for this tool schema, so I supplied empty values for the other required fields, but the install still failed because the GitHub repo root does not contain `SKILL.md`.\n\nIf you want, I can next:\n- inspect the repo for the actual skill path, or\n- try installing from a subdirectory/ref if you provide one."

## Path Install Conversation

- Conversation id: `019cf5f2-a914-7cac-868b-4997892ce126`
- Task names: skills_install
- Approval count: 1
- Installed skill path: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-82998-5eeg7k/claw-019ced08-d411-721d-afbd-805fad46840b/skills/verification-before-completion/SKILL.md`
- Source hash: `b48ae0bb4497aa18fdc8a60e16f35605db0ab205343f6c7a374330d36e7750a0`
- Installed hash: `b48ae0bb4497aa18fdc8a60e16f35605db0ab205343f6c7a374330d36e7750a0`
- Provenance path: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-82998-5eeg7k/claw-019ced08-d411-721d-afbd-805fad46840b/.state/skills/verification-before-completion.json`
- Next-top-level-turn description: Use when about to claim work is complete, fixed, or passing, before committing or creating PRs - requires running verification commands and confirming output before making any success claims; evidence before assertions always
- Exact byte match to upstream raw file: true

## Usage Conversation

- Conversation id: `019cf5f2-dfce-7fd8-af15-7493f4d171d2`
- Task names: skills_load, write, read
- Proof file: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-superpowers-live-20260316-82998-5eeg7k/claw-019ced08-d411-721d-afbd-805fad46840b/conversations/019cf5f2-dfce-7fd8-af15-7493f4d171d2/artifacts/superpowers-skill-proof.txt`
- Proof file content: "SUPERPOWERS_INSTALL_PROOF_deb9dd45\n"
- Final reply: "VERIFIED: SUPERPOWERS_INSTALL_PROOF_deb9dd45"
