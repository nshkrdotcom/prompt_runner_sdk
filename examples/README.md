# Examples

These examples all use the 0.8.1 packet/profile workflow.

## Included Examples

| Example | Provider | Focus | What It Demonstrates |
|---------|----------|-------|----------------------|
| `authoring_packet/` | simulated | Authoring UX | How to go from packet-local ADRs/docs to finished prompts, verification contracts, checklist files, and a runnable packet |
| `simulated_recovery_packet/` | simulated | Recovery UX | Built-in retry, repair, verifier override, retry exhaustion handling, rate-limit handling, and session resume without any external provider CLI |
| `single_repo_packet/` | Codex | Quickstart | One packet, one repo, deterministic verification, packet-local runtime state |
| `claude_packet/` | Claude | Provider portability | The same two prompts as `single_repo_packet/`, run on the Claude lane instead |
| `multi_repo_packet/` | Codex | Cross-repo work | Named repos, repo-scoped verification, Codex additional directories, per-repo commits |

The two simulated packets need no provider CLI at all. `single_repo_packet/`
and `multi_repo_packet/` need the Codex CLI; `claude_packet/` needs the Claude
CLI. All provider examples run against live providers — Prompt Runner ships no
mock provider lane.

## Which Code The Examples Run Against

Running `mix prompt_runner ...` from this repository always uses the **local
working tree**, not the published package, and by default it resolves
`agent_session_manager` and `cli_subprocess_core` from sibling checkouts if you
have them. That is the right default for developing Prompt Runner, but it does
not tell you what a released install does.

Check what you are actually about to run:

```bash
mix deps.sources
```

To exercise the **published** stack instead, there are two levels:

1. Published ASM/core, local Prompt Runner — add the gitignored
   `.dependency_sources.local.exs` described in the
   [README](../README.md#dependency-sources), then `mix deps.get`.
2. Fully published — use Prompt Runner from Hex in a throwaway project and copy
   an example packet into it:

   ```bash
   mix new consumer && cd consumer
   # deps: {:prompt_runner_sdk, "~> 0.8.1"}
   mix deps.get
   cp -r ../prompt_runner_sdk/examples/single_repo_packet pkt
   bash pkt/setup.sh
   mix prompt_runner run pkt
   ```

   Nothing resolves to a sibling checkout there, so this is the honest check
   that a release works for a real consumer.

## Common Flow

From the project root:

```bash
bash examples/authoring_packet/setup.sh
mix prompt_runner list examples/authoring_packet
mix prompt_runner packet preflight examples/authoring_packet
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
mix prompt_runner packet preflight examples/simulated_recovery_packet
mix prompt_runner run examples/simulated_recovery_packet
mix prompt_runner status examples/simulated_recovery_packet
bash examples/simulated_recovery_packet/cleanup.sh
```

Or:

```bash
bash examples/single_repo_packet/setup.sh
mix prompt_runner list examples/single_repo_packet
mix prompt_runner packet preflight examples/single_repo_packet
mix prompt_runner run examples/single_repo_packet
mix prompt_runner status examples/single_repo_packet
bash examples/single_repo_packet/cleanup.sh
```

Or:

```bash
bash examples/claude_packet/setup.sh
mix prompt_runner list examples/claude_packet
mix prompt_runner packet preflight examples/claude_packet
mix prompt_runner run examples/claude_packet
mix prompt_runner status examples/claude_packet
bash examples/claude_packet/cleanup.sh
```

Or:

```bash
bash examples/multi_repo_packet/setup.sh
mix prompt_runner list examples/multi_repo_packet
mix prompt_runner packet preflight examples/multi_repo_packet
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
- `single_repo_packet/` and `claude_packet/` run the identical prompt pair on
  Codex and Claude respectively, so they are the shortest demonstration that a
  packet is provider-portable
- all five examples create their repos or workspaces locally under the
  example directory; run the example `setup.sh` before `packet preflight`
- all five examples clear `.prompt_runner/` on setup so runs start clean
- the packet examples in this directory are meant to be executed with
  `mix prompt_runner ...` from the repository root
