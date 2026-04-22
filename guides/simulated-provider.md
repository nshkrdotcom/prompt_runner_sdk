# Simulated Provider

Prompt Runner ships a built-in `simulated` provider for deterministic recovery
demos, tests, and onboarding.

It requires no external provider CLI and no API credentials.

This provider is intentionally scoped to Prompt Runner package tests, recovery
demos, and onboarding. It is not the cross-stack service-mode simulation path;
for service-mode proofs, configure ASM and `cli_subprocess_core` runtime
profiles so provider execution still goes through the normal ASM core lane.

## When To Use It

- prove retry behavior
- prove repair behavior
- prove provider-session resume behavior
- prove retry behavior across multiple remote-claimed classes such as capacity,
  rate limits, auth/config/runtime claims, and transport timeout
- teach packet/runtime concepts on any machine

## Quick Start

Initialize Prompt Runner once:

```bash
mix prompt_runner init
```

Create a simulated packet:

```bash
mix prompt_runner packet new recovery-demo \
  --profile simulated-default \
  --provider simulated \
  --model simulated-demo \
  --permission bypass
```

Then make the packet-level recovery posture explicit:

```yaml
recovery:
  resume_attempts: 2
  retry:
    max_attempts: 3
    base_delay_ms: 0
    max_delay_ms: 0
    jitter: false
  repair:
    enabled: true
    max_attempts: 2
    trigger_on_nominal_success_with_failed_verifier: true
    trigger_on_provider_failure_with_workspace_changes: true
    trigger_on_retry_exhaustion_with_workspace_changes: true
```

## Prompt Script Format

Use `simulate:` in prompt front matter:

```yaml
simulate:
  attempts:
    - error:
        kind: "provider_capacity"
        message: "Selected model is at capacity. Please try again."
    - writes:
        - path: "retry.txt"
          text: "retry ok"
  resume:
    writes:
      - path: "resumed.txt"
        text: "resumed ok"
```

## Step Keys

Each simulated step can include:

- `messages`
- `writes`
- `error`

`writes` supports:

- `path`
- `text`
- `append`
- optional `repo`

## Recovery Semantics

- `attempts[0]` drives the first run attempt
- later `attempts[...]` entries drive retry or repair attempts
- `resume` drives `resume_stream/3` after a recoverable transport failure

Supported built-in error kinds include:

- `provider_capacity`
- `provider_rate_limit`
- `provider_auth_claim`
- `provider_config_claim`
- `provider_runtime_claim`
- `protocol_error`
- `transport_disconnect`
- `transport_timeout`
- `approval_denied`
- `guardrail_blocked`
- `user_cancelled`

The verifier still decides completion. The simulated provider only drives the
runtime events and filesystem side effects.

## Example Pack

See [examples/simulated_recovery_packet/README.md](../examples/simulated_recovery_packet/README.md).
