---
name: "simulated-recovery-packet"
profile: "simulated-default"
provider: "simulated"
model: "simulated-demo"
permission_mode: "bypass"
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
  "1": "Automatic Recovery"
  "2": "Verifier Override"
  "3": "Session Recovery"
  "4": "Additional Recovery Modes"
---
# Simulated Recovery Packet

Zero-dependency recovery demo for Prompt Runner 0.7.0.
