# Simulated Recovery Packet

This example demonstrates Prompt Runner's recovery behavior without requiring
Codex, Claude, Gemini, or Amp.

It uses the built-in `simulated` provider to prove three cases:

- prompt `01`: automatic retry after transient provider capacity
- prompt `02`: automatic repair after verifier-detected incompletion
- prompt `03`: automatic provider-session resume after recoverable transport
  failure

## Run It

From the project root:

```bash
bash examples/simulated_recovery_packet/setup.sh
mix prompt_runner list examples/simulated_recovery_packet
mix prompt_runner run examples/simulated_recovery_packet
mix prompt_runner status examples/simulated_recovery_packet
bash examples/simulated_recovery_packet/cleanup.sh
```

## What To Inspect

- `workspace/retry.txt`
- `workspace/hello.txt`
- `workspace/hello.meta.txt`
- `workspace/resumed.txt`
- `.prompt_runner/state.json`

The runtime state shows attempt history, repair/retry progression, and final
verifier results for each prompt.
