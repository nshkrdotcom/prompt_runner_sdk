# Simulated Provider

Prompt Runner ships a built-in `simulated` provider for deterministic recovery
demos, tests, and onboarding.

It requires no external provider CLI and no API credentials.

## When To Use It

- prove retry behavior
- prove repair behavior
- prove provider-session resume behavior
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
  --permission bypass \
  --retry-attempts 2 \
  --auto-repair
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

The verifier still decides completion. The simulated provider only drives the
runtime events and filesystem side effects.

## Example Pack

See [examples/simulated_recovery_packet/README.md](../examples/simulated_recovery_packet/README.md).
