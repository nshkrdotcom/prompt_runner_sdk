# Examples

These examples all use the 0.7.0 packet/profile workflow.

## Included Examples

| Example | Focus | What It Demonstrates |
|---------|-------|----------------------|
| `authoring_packet/` | Authoring UX | How to go from packet-local ADRs/docs to finished prompts, verification contracts, checklist files, and a runnable packet |
| `simulated_recovery_packet/` | Recovery UX | Built-in retry, repair, verifier override, retry exhaustion handling, rate-limit handling, and session resume without any external provider CLI |
| `single_repo_packet/` | Quickstart | One packet, one repo, deterministic verification, packet-local runtime state |
| `multi_repo_packet/` | Cross-repo work | Named repos, repo-scoped verification, Codex additional directories, per-repo commits |

## Common Flow

From the project root:

```bash
bash examples/authoring_packet/setup.sh
mix prompt_runner list examples/authoring_packet
mix prompt_runner packet doctor examples/authoring_packet
mix prompt_runner checklist sync examples/authoring_packet
mix prompt_runner run examples/authoring_packet
mix prompt_runner status examples/authoring_packet
bash examples/authoring_packet/cleanup.sh
```

Or:

```bash
bash examples/simulated_recovery_packet/setup.sh
mix prompt_runner list examples/simulated_recovery_packet
mix prompt_runner run examples/simulated_recovery_packet
mix prompt_runner status examples/simulated_recovery_packet
bash examples/simulated_recovery_packet/cleanup.sh
```

Or:

```bash
bash examples/single_repo_packet/setup.sh
mix prompt_runner list examples/single_repo_packet
mix prompt_runner run examples/single_repo_packet
mix prompt_runner status examples/single_repo_packet
bash examples/single_repo_packet/cleanup.sh
```

Or:

```bash
bash examples/multi_repo_packet/setup.sh
mix prompt_runner list examples/multi_repo_packet
mix prompt_runner run examples/multi_repo_packet
mix prompt_runner status examples/multi_repo_packet
bash examples/multi_repo_packet/cleanup.sh
```

## Notes

- `authoring_packet/` is the best place to start if you already have ADRs or
  design docs and want to see how Prompt Runner turns them into packet-local
  prompts and verifier contracts
- `simulated_recovery_packet/` is the best place to learn retry, repair, and
  resume behavior because it requires no external provider CLI at all and now
  proves capacity, rate-limit, protocol-drop, transport-timeout, repair, and
  verifier-override behavior in one successful walkthrough
- all four examples create their repos or workspaces locally under the
  example directory
- all four examples clear `.prompt_runner/` on setup so runs start clean
- the packet examples in this directory are meant to be executed with
  `mix prompt_runner ...` from the repository root
