# Claude Packet Example

The live Claude provider walkthrough. It runs the same two prompts as
[`../single_repo_packet/`](../single_repo_packet/README.md), which uses Codex,
so the pair demonstrates that a packet is provider-portable.

## Requirements

The Claude CLI must be installed and authenticated:

```bash
npm install -g @anthropic-ai/claude-code
claude --version
```

Prompt Runner drives Claude over ASM's core lane, so `claude_agent_sdk` is not
a required dependency of your project.

## What It Covers

- `provider: claude` with a `claude_opts` section
- prompt-local verification contracts
- generated checklist files
- packet-local runtime state in `.prompt_runner/`
- git commits after verification passes

## Setup

From the project root:

```bash
bash examples/claude_packet/setup.sh
```

That creates a local git repo at:

```text
examples/claude_packet/workspace
```

## Inspect And Run

```bash
mix prompt_runner list examples/claude_packet
mix prompt_runner packet preflight examples/claude_packet
mix prompt_runner plan examples/claude_packet
mix prompt_runner run examples/claude_packet
mix prompt_runner status examples/claude_packet
```

## Expected Outputs

After a successful run:

- `workspace/hello.txt`
- `workspace/SUMMARY.md`

The runtime directory contains:

- `.prompt_runner/state.json`
- `.prompt_runner/progress.log`
- `.prompt_runner/logs/`

## Switching Providers

The packet manifest is the only thing that changes between this example and
the Codex one:

```yaml
provider: "claude"
model: "haiku"
```

Swap those two lines for `provider: "codex"` and a Codex model such as
`gpt-5.6-luna` to run the identical prompts on the other lane.

## Cleanup

```bash
bash examples/claude_packet/cleanup.sh
```
