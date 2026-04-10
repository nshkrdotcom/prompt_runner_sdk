# Multi Repo Packet Example

This example shows one packet coordinating two repos.

## What It Covers

- named repos in `prompt_runner_packet.md`
- repo-scoped verification contracts
- cross-repo Codex access through `codex_thread_opts.additional_directories`
- per-repo git commits after verification passes

## Setup

From the project root:

```bash
bash examples/multi_repo_packet/setup.sh
```

That creates:

```text
examples/multi_repo_packet/repos/alpha
examples/multi_repo_packet/repos/beta
```

## Inspect And Run

```bash
mix prompt_runner list examples/multi_repo_packet
mix prompt_runner plan examples/multi_repo_packet
mix prompt_runner run examples/multi_repo_packet
mix prompt_runner status examples/multi_repo_packet
```

## Expected Outputs

After a successful run:

- `repos/alpha/NOTES.md`
- `repos/beta/NOTES.md`
- `repos/alpha/CROSS_REPO_SUMMARY.md`

## Cleanup

```bash
bash examples/multi_repo_packet/cleanup.sh
```
