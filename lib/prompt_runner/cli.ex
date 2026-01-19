defmodule PromptRunner.CLI do
  @moduledoc false

  alias PromptRunner.Config
  alias PromptRunner.Runner
  alias PromptRunner.UI

  @spec main(list()) :: :ok | no_return()
  def main(args \\ System.argv()) do
    {opts, remaining, _} = parse_args(args)

    cond do
      opts[:help] ->
        show_help()

      opts[:config] == nil ->
        handle_missing_config()

      true ->
        run_with_config(opts, remaining)
    end
  end

  defp parse_args(args) do
    OptionParser.parse(args,
      switches: [
        help: :boolean,
        config: :string,
        list: :boolean,
        validate: :boolean,
        dry_run: :boolean,
        run: :boolean,
        plan_only: :boolean,
        no_commit: :boolean,
        project_dir: :string,
        repo_override: :keep,
        log_mode: :string,
        log_meta: :string,
        events_mode: :string,
        phase: :integer,
        all: :boolean,
        continue: :boolean,
        branch_strategy: :string,
        branch_name: :string,
        auto_pr: :boolean,
        partial_mode: :string,
        partial_continue: :boolean
      ],
      aliases: [
        h: :help,
        c: :config,
        l: :list,
        v: :validate,
        p: :plan_only
      ]
    )
  end

  defp run_with_config(opts, remaining) do
    case Config.load(opts[:config]) do
      {:ok, config} ->
        handle_runner_result(Runner.run(config, opts, remaining))

      error ->
        handle_config_error(error)
    end
  end

  defp handle_runner_result(:ok), do: :ok

  defp handle_runner_result({:error, :no_command}) do
    show_help()
    System.halt(1)
  end

  defp handle_runner_result({:error, :no_target}) do
    IO.puts(UI.red("ERROR: No target specified"))
    show_help()
    System.halt(1)
  end

  defp handle_runner_result({:error, reason}) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    System.halt(1)
  end

  @spec handle_config_error({:error, term()}) :: no_return()
  defp handle_config_error({:error, {:config_not_found, path}}) do
    IO.puts(UI.red("ERROR: Config file not found: #{path}"))
    System.halt(1)
  end

  defp handle_config_error({:error, {:invalid_llm_sdk, reason}}) do
    IO.puts(UI.red("ERROR: Invalid llm_sdk: #{inspect(reason)}"))
    System.halt(1)
  end

  defp handle_config_error({:error, errors}) when is_list(errors) do
    IO.puts(UI.red("ERROR: Config validation failed"))

    Enum.each(Enum.reverse(errors), fn {key, detail} ->
      IO.puts("  - #{key}: #{inspect(detail)}")
    end)

    System.halt(1)
  end

  defp handle_config_error({:error, reason}) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    System.halt(1)
  end

  @spec handle_missing_config() :: no_return()
  defp handle_missing_config do
    IO.puts(UI.red("ERROR: --config is required"))
    IO.puts("")
    IO.puts("Usage: mix run run_prompts.exs --config <config_file> [command] [options]")
    IO.puts("")
    IO.puts("Run with --help for more information.")
    System.halt(1)
  end

  defp show_help do
    IO.puts("")
    IO.puts(UI.bold("Generic Implementation Prompt Runner (Elixir)"))
    IO.puts("")
    IO.puts("Usage: mix run run_prompts.exs --config <config_file> [COMMAND] [OPTIONS]")
    IO.puts("")

    IO.puts(UI.yellow("Required:"))
    IO.puts("    --config, -c FILE   Configuration file (required)")
    IO.puts("")

    IO.puts(UI.yellow("Commands:"))
    IO.puts("    --list              List all prompts with status")
    IO.puts("    --validate, -v      Comprehensive config validation")
    IO.puts("    --dry-run TARGET    Preview what would execute")
    IO.puts("    --plan-only, -p     Generate execution plan without running")
    IO.puts("    --run TARGET        Execute prompts with streaming output")
    IO.puts("")

    IO.puts(UI.yellow("Targets:"))
    IO.puts("    NN                  Single prompt (e.g., 01, 15)")
    IO.puts("    --phase N           All prompts in phase 1-5")
    IO.puts("    --all               All prompts")
    IO.puts("    --continue          Resume from last completed")
    IO.puts("    --partial-continue  Resume failed repos from partial_success")
    IO.puts("")

    IO.puts(UI.yellow("Options:"))
    IO.puts("    --no-commit             Skip git commit after prompt")
    IO.puts("    --project-dir DIR       Override project directory (legacy single-repo)")
    IO.puts("    --repo-override N:P     Override repo path by name (repeatable)")
    IO.puts("    --log-mode MODE         Log output mode: compact (default) or verbose")
    IO.puts("    --log-meta MODE         Event metadata: none (default) or full")
    IO.puts("    --events-mode MODE      Events log: compact (default), full, or off")
    IO.puts("")

    IO.puts(UI.yellow("Branch Strategy:"))

    IO.puts(
      "    --branch-strategy MODE  Branch mode: direct (default), feature_branch, per_prompt"
    )

    IO.puts("    --branch-name NAME      Override branch name")
    IO.puts("    --auto-pr               Create PRs after completion")
    IO.puts("")

    IO.puts(UI.yellow("Partial Success:"))

    IO.puts(
      "    --partial-mode MODE     Partial failure: fail_fast (default), continue, require_all"
    )

    IO.puts("    --partial-continue      Resume from partial_success state")
    IO.puts("")

    IO.puts(UI.yellow("Examples:"))
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --list")
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --dry-run 01")
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --dry-run --phase 1")
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --run 01")
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --run --all")
    IO.puts("    mix run run_prompts.exs --config runner_config.exs --run --continue --no-commit")
    IO.puts("")

    IO.puts(UI.yellow("Config File Format (Elixir):"))
    IO.puts(~S"    %{")
    IO.puts(~S|      project_dir: "/path/to/project",|)
    IO.puts("")
    IO.puts("      target_repos: [")
    IO.puts(~S|        %{name: "command", path: "/path/to/command", default: true},|)
    IO.puts(~S|        %{name: "flowstone", path: "/path/to/flowstone"}|)
    IO.puts("      ],")
    IO.puts("")
    IO.puts("      llm: %{")
    IO.puts(~S|        sdk: "claude_agent_sdk",|)
    IO.puts(~S|        model: "sonnet",|)
    IO.puts("        prompt_overrides: %{")
    IO.puts(~S|          "02" => %{sdk: "codex_sdk", model: "gpt-5.1-codex"}|)
    IO.puts("        }")
    IO.puts("      },")
    IO.puts("")
    IO.puts(~S|      prompts_file: "prompts.txt",|)
    IO.puts(~S|      commit_messages_file: "commit-messages.txt",|)
    IO.puts(~S|      progress_file: ".progress",|)
    IO.puts(~S|      log_dir: "../logs",|)
    IO.puts(~S|      model: "sonnet",|)
    IO.puts(~S|      allowed_tools: ["Read", "Write"],|)
    IO.puts("      permission_mode: :accept_edits,")
    IO.puts("      log_mode: :compact,")
    IO.puts("      log_meta: :none,")
    IO.puts("      events_mode: :compact,")
    IO.puts(~S|      phase_names: %{1 => "Phase One"}|)
    IO.puts("    }")
    IO.puts("")

    IO.puts(UI.yellow("Prompts File Format:"))
    IO.puts("    # Format: NUM|PHASE|SP|NAME|FILE[|TARGET_REPOS]")
    IO.puts("    01|1|5|Schema|001-schema.md")
    IO.puts("    02|1|8|FlowStone|002-flowstone.md|command,flowstone")
    IO.puts("")

    IO.puts(UI.yellow("Commit Messages File Format:"))
    IO.puts("    === COMMIT 01 ===")
    IO.puts("    feat(module): description")
    IO.puts("")
    IO.puts("    === COMMIT 02:command ===")
    IO.puts("    feat(command): changes for command repo")
    IO.puts("")
    IO.puts("    === COMMIT 02:flowstone ===")
    IO.puts("    feat(flowstone): changes for flowstone repo")
    IO.puts("")
  end
end
