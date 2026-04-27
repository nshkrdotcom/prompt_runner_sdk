# Single Repo Packet Example

This is the quickest end-to-end packet example in the repo.

If you want the authoring workflow from ADRs/docs to finished prompts, start
with [`../authoring_packet/`](../authoring_packet/README.md) instead.

## What It Covers

- `prompt_runner_packet.md`
- prompt-local verification contracts
- generated checklist files
- packet-local runtime state in `.prompt_runner/`
- git commits after verification passes

## Setup

From the project root:

```bash
bash examples/single_repo_packet/setup.sh
```

That creates a local git repo at:

```text
examples/single_repo_packet/workspace
```

## Inspect And Run

```bash
mix prompt_runner list examples/single_repo_packet
mix prompt_runner packet preflight examples/single_repo_packet
mix prompt_runner plan examples/single_repo_packet
mix prompt_runner run examples/single_repo_packet
mix prompt_runner status examples/single_repo_packet
```

## Expected Outputs

After a successful run:

- `workspace/hello.txt`
- `workspace/SUMMARY.md`

The runtime directory contains:

- `.prompt_runner/state.json`
- `.prompt_runner/progress.log`
- `.prompt_runner/logs/`

## Cleanup

```bash
bash examples/single_repo_packet/cleanup.sh
```
