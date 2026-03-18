# Claw Workspace Env Overlay Proof

- Date: 2026-03-18
- Started at (UTC): 2026-03-18T02:12:41Z
- Finished at (UTC): 2026-03-18T02:13:39Z
- Model ref: openrouter/openai-gpt-5.4-live-acceptance
- Environment: development @ Juns-MacBook-Pro-M4-2419.local
- Workspace root base: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-51436-rvzzvw`
- Scenario id: `rbenv_shell_resolution`
- Lane env path: `.lanes/019cfeb7-783a-77a6-ada8-21221c5357ad/.env.agent`
- Root env path: `../../.env.agent`
- Approval count: 5
- Conversation ids: 019cfeb7-782c-7d20-aa16-e0254b12c3f6, 019cfeb8-3445-798c-a0d4-9a3b6240eed2

## Expected interactive zsh target

| Field | Value |
| --- | --- |
| bundle_gemfile | `` |
| bundle_path | `/Users/jasl/.rbenv/shims/bundle` |
| bundle_version | `4.0.7` |
| rbenv_root | `/Users/jasl/.rbenv` |
| ruby_path | `/Users/jasl/.rbenv/shims/ruby` |
| ruby_version | `ruby 4.0.1 (2026-01-13 revision e04267a14b) +PRISM [arm64-darwin25]` |
| rubyopt | `` |

## Baseline

| Field | Value |
| --- | --- |
| bundle_gemfile | `/tmp/cybros-live-acceptance-poisoned/Gemfile` |
| bundle_path | `/usr/bin/bundle` |
| bundle_version | `/Users/jasl/.rbenv/versions/4.0.1/lib/ruby/site_ruby/4.0.0/bundler/definition.rb:38:in /Users/jasl/.rbenv/versions/4.0.1/lib/ruby/site_ruby/4.0.0/bundler/definition.rb:38:in build': /tmp/cybros-live-acceptance-poisoned/Gemfile not found (Bundler::GemfileNotFound)` |
| env_files_loaded | `[]` |
| exit_code | `0` |
| rbenv_root | `/Users/jasl/.rbenv` |
| ruby_path | `/usr/bin/ruby` |
| ruby_version | `ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin25]` |
| rubyopt | `-W0` |

## Lane-local fix

| Field | Value |
| --- | --- |
| bundle_gemfile | `` |
| bundle_path | `/Users/jasl/.rbenv/shims/bundle` |
| bundle_version | `4.0.7` |
| env_files_loaded | `["/private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-51436-rvzzvw/bundled/claw/conversations/019cfeb7-782c-7d20-aa16-e0254b12c3f6/.lanes/019cfeb7-783a-77a6-ada8-21221c5357ad/.env.agent"]` |
| exit_code | `0` |
| rbenv_root | `/Users/jasl/.rbenv` |
| ruby_path | `/Users/jasl/.rbenv/shims/ruby` |
| ruby_version | `ruby 4.0.1 (2026-01-13 revision e04267a14b) +PRISM [arm64-darwin25]` |
| rubyopt | `` |

## Promoted root fix

| Field | Value |
| --- | --- |
| bundle_gemfile | `` |
| bundle_path | `/Users/jasl/.rbenv/shims/bundle` |
| bundle_version | `4.0.7` |
| env_files_loaded | `["/private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-51436-rvzzvw/bundled/claw/.env.agent"]` |
| exit_code | `0` |
| rbenv_root | `/Users/jasl/.rbenv` |
| ruby_path | `/Users/jasl/.rbenv/shims/ruby` |
| ruby_version | `ruby 4.0.1 (2026-01-13 revision e04267a14b) +PRISM [arm64-darwin25]` |
| rubyopt | `` |

## Simulated process env

```
BUNDLE_GEMFILE=/tmp/cybros-live-acceptance-poisoned/Gemfile
HOME=/Users/jasl
PATH=/usr/bin:/bin:/usr/sbin:/sbin
RUBYOPT=-W0
```
