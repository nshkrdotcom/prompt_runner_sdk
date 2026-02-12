#!/usr/bin/env elixir

# Standalone runner for the multi-repo dummy example.
#
# From the example directory:
#   cd examples/multi_repo_dummy
#   elixir run_prompts.exs --run --all
#   elixir run_prompts.exs --list
#
# Or with explicit config:
#   elixir run_prompts.exs -c runner_config.exs --run 01

Application.ensure_all_started(:inets)

Mix.install([
  {:prompt_runner_sdk, path: Path.expand("../..", __DIR__)},
  {:claude_agent_sdk, "~> 0.14.0"},
  {:codex_sdk, "~> 0.10.1"},
  {:amp_sdk, "~> 0.4.0"}
])

args = System.argv()

has_config? =
  Enum.any?(args, fn arg ->
    arg in ["-c", "--config"] or String.starts_with?(arg, "--config=")
  end)

args =
  if has_config? do
    args
  else
    ["--config", Path.join(__DIR__, "runner_config.exs") | args]
  end

PromptRunner.CLI.main(args)
