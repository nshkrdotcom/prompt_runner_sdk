# Verification And Repair

Prompt Runner 0.7.0 treats deterministic verification as the source of truth
for prompt completion.

## Contract Keys

Supported checks:

- `files_exist`
- `files_absent`
- `contains`
- `matches`
- `commands`
- `changed_paths_only`

Example:

```yaml
verify:
  files_exist:
    - "hello.txt"
  contains:
    - path: "hello.txt"
      text: "Hello from Prompt Runner"
  changed_paths_only:
    - "hello.txt"
```

## Outcome Matrix

After each attempt, Prompt Runner combines the provider outcome with the
verifier report:

- provider success + verifier pass => complete
- provider success + verifier fail => repair
- provider failure + verifier pass => complete unless the failure is a local
  deterministic contradiction such as CLI confirmation mismatch
- remote/provider-claimed auth, config, model-unavailable, capacity, and
  generic runtime failures => bounded retries by policy
- provider failure + verifier fail + partial workspace progress => repair
- retry exhaustion + partial workspace progress => repair
- local deterministic failure => fail

## Retry, Resume, And Repair

Retry is for remote/provider-claimed failures that may be flaky or mislabeled,
including auth, config, model-unavailable, capacity, and generic runtime
claims.

Resume is the first recovery step for recoverable transport/protocol failures.

Repair is for semantic incompletion or partial workspace progress. Prompt
Runner synthesizes a repair prompt from the unmet verifier items rather than
blindly replaying the original instruction.

Packet-level recovery defaults live in `prompt_runner_packet.md`, and a prompt
can tighten or relax them with its own front-matter `recovery:` block. This is
useful when one prompt should exhaust retries faster and pivot into repair
sooner than the rest of the packet.

## Checklist Views

Generate packet-local checklist files with:

```bash
mix prompt_runner checklist sync /path/to/packet
```

Those checklist files are for human navigation. The verifier report remains the
actual completion source of truth.

## Deterministic Recovery Demos

Use the built-in `simulated` provider when you want to prove retry, repair, or
resume behavior without relying on a real provider outage.

The shipped simulated packet covers successful recovery for:

- provider capacity
- provider rate limits
- remote auth claims
- remote config/model-unavailable claims
- late remote runtime errors after correct output
- retry exhaustion followed by repair
- protocol disconnect resume
- transport-timeout resume

Terminal remote claims such as approval denial, guardrail blocks, and explicit
user cancellation are covered in the automated test suite so the example pack
remains a clean, fully successful walkthrough.

See:

- `examples/simulated_recovery_packet/`
- [Simulated Provider](simulated-provider.md)

## Runtime State

Packet-local state is stored in:

```text
.prompt_runner/state.json
```

It records:

- prompt status
- attempt history
- verifier results
- failure class
- repair/retry progression
