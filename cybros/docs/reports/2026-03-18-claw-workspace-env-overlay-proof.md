# Claw Workspace Env Overlay Proof

- Date: 2026-03-18
- Started at (UTC): 2026-03-18T11:53:55Z
- Finished at (UTC): 2026-03-18T11:54:59Z
- Model ref: openrouter/openai-gpt-5.4-live-acceptance
- Environment: development @ Juns-MacBook-Pro-M4-2419.local
- Workspace root base: `/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-30729-g119nt`
- Scenario id: `rbenv_shell_resolution`
- Lane env path: `.lanes/019d00cb-9c81-7d2b-939f-362b625b27c5/.env.agent`
- Root env path: `../../.env.agent`
- Approval count: 5
- Conversation ids: 019d00cb-9c4a-7ff1-bc95-06f5bceedd8e, 019d00cc-6e04-7f31-b4fb-d1b885e1f5aa

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
| env_files_loaded | `["/private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-30729-g119nt/bundled/claw/conversations/019d00cb-9c4a-7ff1-bc95-06f5bceedd8e/.lanes/019d00cb-9c81-7d2b-939f-362b625b27c5/.env.agent"]` |
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
| env_files_loaded | `["/private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/cybros-agent-root-live-20260318-30729-g119nt/bundled/claw/.env.agent"]` |
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
