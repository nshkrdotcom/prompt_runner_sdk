# Examples

These examples all use the 0.7.0 packet/profile workflow.

## Included Examples

| Example | Focus | What It Demonstrates |
|---------|-------|----------------------|
| `simulated_recovery_packet/` | Recovery UX | Built-in retry, repair, and session resume without any external provider CLI |
| `single_repo_packet/` | Quickstart | One packet, one repo, deterministic verification, packet-local runtime state |
| `multi_repo_packet/` | Cross-repo work | Named repos, repo-scoped verification, Codex additional directories, per-repo commits |

## Common Flow

From the project root:

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

- `simulated_recovery_packet/` is the best place to learn retry, repair, and
  resume behavior because it requires no external provider CLI at all
- all three examples create their repos or workspaces locally under the
  example directory
- all three examples clear `.prompt_runner/` on setup so runs start clean
- the packet examples in this directory are meant to be executed with
  `mix prompt_runner ...` from the repository root
