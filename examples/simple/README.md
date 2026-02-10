# Simple Example

This example includes two prompts that write files into an isolated workspace:

- Prompt 01 uses Claude Agent SDK and writes `workspace/claude-output.txt`.
- Prompt 02 uses Codex SDK and writes `workspace/codex-output.txt`.

## 1) Create the workspace

```bash
bash examples/simple/setup.sh
```

## 2) Run the prompts

**From the project root:**

```bash
mix run run_prompts.exs --config examples/simple/runner_config.exs --list
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 01
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 02
```

**From the example directory (standalone):**

```bash
cd examples/simple
elixir run_prompts.exs --list
elixir run_prompts.exs --run 01
elixir run_prompts.exs --run 02
```

## 3) Clean up

```bash
bash examples/simple/cleanup.sh
```
