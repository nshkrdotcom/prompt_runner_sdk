# Simple Example

This example includes two prompts that write files into the repo:

- Prompt 01 uses Claude Agent SDK and writes `examples/simple/claude-output.txt`.
- Prompt 02 uses Codex SDK and writes `examples/simple/codex-output.txt`.

## Run

```bash
cd /home/home/p/g/n/prompt_runner_sdk
mix run run_prompts.exs --config examples/simple/runner_config.exs --list
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 01
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 02
```

## Files written

- `examples/simple/claude-output.txt`
- `examples/simple/codex-output.txt`
