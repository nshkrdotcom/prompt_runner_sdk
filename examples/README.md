# Examples

These examples all use the 0.7.0 packet/profile workflow.

## Included Examples

| Example | Focus | What It Demonstrates |
|---------|-------|----------------------|
| `single_repo_packet/` | Quickstart | One packet, one repo, deterministic verification, packet-local runtime state |
| `multi_repo_packet/` | Cross-repo work | Named repos, repo-scoped verification, Codex additional directories, per-repo commits |

## Common Flow

From the project root:

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

- both examples create their repos or workspaces locally under the example
  directory
- both examples clear `.prompt_runner/` on setup so runs start clean
- both examples are meant to be executed with the repository root Mix task or
  `run_prompts.exs`
- the repair workflow is documented in
  `guides/verification-and-repair.md` instead of a standalone intentionally
  failing example pack
