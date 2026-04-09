# Simple Example

This example includes four prompts that write files into an isolated workspace:

- Prompt 01 uses Claude Agent SDK and writes `workspace/claude-output.txt`.
- Prompt 02 uses Codex SDK and writes `workspace/codex-output.txt`.
- Prompt 03 uses Amp SDK and writes `workspace/amp-output.txt`.
- Prompt 04 uses Gemini CLI SDK and writes `workspace/gemini-output.txt`.

## 1) Create the workspace

The setup script resets and reseeds the example workspace each time.

```bash
bash examples/simple/setup.sh
```

## 2) Run the prompts

**From the project root:**

```bash
mix run run_prompts.exs --config examples/simple/runner_config.exs --list
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 01
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 02
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 03
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 04
```

**From the example directory (standalone):**

```bash
cd examples/simple
elixir run_prompts.exs --list
elixir run_prompts.exs --run 01
elixir run_prompts.exs --run 02
elixir run_prompts.exs --run 03
elixir run_prompts.exs --run 04
```

## 3) Clean up

```bash
bash examples/simple/cleanup.sh
```

## Recovery Notes

The simple example pack is the fastest way to verify that Prompt Runner still distinguishes:

- prompt-list continuation (`--continue` through the prompt plan)
- provider-session continuation (resume the same underlying provider session with `Continue`)

Those are intentionally separate flows in the hardened runner.
