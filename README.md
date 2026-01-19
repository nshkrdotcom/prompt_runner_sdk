# PromptRunner SDK

Prompt runner CLI that supports both Claude Code SDK and Codex SDK with a shared
streaming facade.

## Usage

```bash
mix deps.get
mix run run_prompts.exs --config examples/simple/runner_config.exs --list
mix run run_prompts.exs --config examples/simple/runner_config.exs --dry-run 01
mix run run_prompts.exs --config examples/simple/runner_config.exs --run 01
```

The `examples/simple` folder contains a two-prompt demo where prompt 01 uses
Claude Code SDK and prompt 02 overrides to Codex SDK.
