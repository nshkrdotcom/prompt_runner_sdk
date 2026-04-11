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
- transient provider failure + verifier pass => complete
- transient provider failure + verifier fail => retry
- terminal policy/config/auth failure => fail

## Retry And Repair

Retry is for transient runtime failures such as provider capacity or
recoverable transport interruptions.

Repair is for semantic incompletion. Prompt Runner synthesizes a repair prompt
from the unmet verifier items rather than blindly replaying the original
instruction.

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
