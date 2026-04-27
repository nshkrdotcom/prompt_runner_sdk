# Simulated Recovery Packet

This example demonstrates Prompt Runner's recovery behavior without requiring
Codex, Claude, Gemini, or Amp.

It uses the built-in `simulated` provider to prove the full recovery matrix:

- prompt `01`: automatic retry after transient provider capacity
- prompt `02`: automatic repair after verifier-detected incompletion
- prompt `03`: automatic provider-session resume after recoverable transport
  failure
- prompt `04`: automatic retry after a remote auth claim
- prompt `05`: automatic retry after a remote config/model-unavailable claim
- prompt `06`: verifier-owned completion even when the provider reports a late
  runtime error
- prompt `07`: repair after retry exhaustion once the workspace has partially
  changed, using a prompt-local `recovery:` override to tighten the runtime
  failure retry budget
- prompt `08`: automatic retry after a remote rate-limit claim
- prompt `09`: automatic provider-session resume after a transport timeout

Terminal remote claims such as `approval_denied`, `guardrail_blocked`, and
`user_cancelled` are intentionally kept in the test suite instead of this
example pack so the walkthrough remains a fully successful end-to-end run.

## Run It

From the project root:

```bash
bash examples/simulated_recovery_packet/setup.sh
mix prompt_runner list examples/simulated_recovery_packet
mix prompt_runner packet preflight examples/simulated_recovery_packet
mix prompt_runner run examples/simulated_recovery_packet
mix prompt_runner status examples/simulated_recovery_packet
bash examples/simulated_recovery_packet/cleanup.sh
```

## What To Inspect

- `workspace/retry.txt`
- `workspace/hello.txt`
- `workspace/hello.meta.txt`
- `workspace/resumed.txt`
- `workspace/auth.txt`
- `workspace/config.txt`
- `workspace/override.txt`
- `workspace/draft.txt`
- `workspace/draft.meta.txt`
- `workspace/rate-limit.txt`
- `workspace/timeout-resumed.txt`
- `.prompt_runner/state.json`

The runtime state shows attempt history, repair/retry progression, and final
verifier results for each prompt.
