---
name: "single-repo-packet"
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
repos:
  app:
    path: "./workspace"
    default: true
phases:
  "1": "Bootstrap"
  "2": "Wrap Up"
---
# Single Repo Packet

Friendly single-repo packet example for Prompt Runner 0.7.0.
