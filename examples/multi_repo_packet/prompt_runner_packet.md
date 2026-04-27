---
name: "multi-repo-packet"
profile: "codex-default"
provider: "codex"
model: "gpt-5.4-mini"
reasoning_effort: "low"
permission_mode: "bypass"
allowed_tools:
  - "Read"
  - "Edit"
  - "Write"
  - "Bash"
cli_confirmation: "require"
recovery:
  resume_attempts: 2
  retry:
    max_attempts: 3
    base_delay_ms: 1000
    max_delay_ms: 30000
    jitter: true
    class_attempts:
      provider_capacity: 5
      provider_rate_limit: 5
      provider_auth_claim: 3
      provider_config_claim: 3
      provider_runtime_claim: 3
      transport_disconnect: 4
      transport_timeout: 4
      protocol_error: 4
      unknown: 3
  repair:
    enabled: true
    max_attempts: 2
    trigger_on_nominal_success_with_failed_verifier: true
    trigger_on_provider_failure_with_workspace_changes: true
    trigger_on_retry_exhaustion_with_workspace_changes: true
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
