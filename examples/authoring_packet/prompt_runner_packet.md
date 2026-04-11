---
name: "authoring-packet"
profile: "simulated-default"
prompt_template: "from-adr"
provider: "simulated"
model: "simulated-demo"
reasoning_effort: "low"
permission_mode: "bypass"
allowed_tools:
  - "Read"
  - "Edit"
  - "Write"
  - "Bash"
cli_confirmation: "off"
recovery:
  resume_attempts: 2
  retry:
    max_attempts: 3
    base_delay_ms: 0
    max_delay_ms: 0
    jitter: false
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
repos:
  app:
    path: "./workspace"
    default: true
phases:
  "1": "Discovery"
  "2": "Execution"
---
# Authoring Packet

This packet demonstrates how to move from ADRs and source docs to finished
prompts with deterministic verification contracts.
