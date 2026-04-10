---
name: "multi-repo-packet"
profile: "codex-default"
provider: "codex"
model: "gpt-5.4"
reasoning_effort: "xhigh"
permission_mode: "bypass"
allowed_tools:
  - "Read"
  - "Edit"
  - "Write"
  - "Bash"
cli_confirmation: "require"
retry_attempts: 2
auto_repair: true
codex_thread_opts:
  additional_directories:
    - "./repos/beta"
repos:
  alpha:
    path: "./repos/alpha"
    default: true
  beta:
    path: "./repos/beta"
phases:
  "1": "Cross Repo Bootstrap"
  "2": "Summary"
---
# Multi Repo Packet

Friendly multi-repo packet example for Prompt Runner 0.7.0.
