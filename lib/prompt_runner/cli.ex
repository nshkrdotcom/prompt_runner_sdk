defmodule PromptRunner.CLI do
  @moduledoc """
  Command-line entrypoint for convention and legacy PromptRunner workflows.
  """

  alias PromptRunner
  alias PromptRunner.Runner
  alias PromptRunner.UI

  @spec main(list()) :: :ok | no_return()
  def main(args \\ System.argv()) do
    {opts, remaining, _invalid} = parse_args(args)

    cond do
      opts[:help] ->
        show_help()

      command = command_from_args(remaining) ->
        run_command(command, tl(remaining), opts)

      legacy_mode?(opts) ->
        run_legacy(opts, remaining)

      true ->
        handle_missing_input()
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
        no_commit: :boolean,
        require_cli_confirmation: :boolean,
        cli_confirmation: :string,
        project_dir: :string,
        repo_override: :keep,
        log_mode: :string,
        log_meta: :string,
        events_mode: :string,
        tool_output: :string,
        phase: :integer,
        all: :boolean,
        continue: :boolean,
        target: :keep,
        targets: :keep,
        provider: :string,
        model: :string,
        output: :string,
        state_dir: :string,
        no_state: :boolean,
        runtime_store: :string,
        committer: :string
      ],
      aliases: [
        h: :help,
        c: :config,
        l: :list,
        v: :validate
      ]
    )
  end

  defp command_from_args([command | _])
       when command in ["run", "list", "validate", "plan", "scaffold"],
       do: command

  defp command_from_args(_), do: nil

  defp legacy_mode?(opts) do
    opts[:config] != nil or opts[:list] or opts[:validate] or opts[:dry_run] or opts[:run]
  end

  defp run_command("list", [source | _rest], opts) do
    case PromptRunner.plan(source, cli_opts(opts)) do
      {:ok, plan} ->
        Runner.list_plan(plan)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_command("validate", [source | _rest], opts) do
    case PromptRunner.validate(source, cli_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_command("plan", [source | _rest], opts) do
    case PromptRunner.plan(source, cli_opts(opts)) do
      {:ok, plan} ->
        print_plan_summary(plan)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_command("run", [source | _rest], opts) do
    case PromptRunner.run(source, cli_opts(opts)) do
      {:ok, _run} -> :ok
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_command("scaffold", [source | _rest], opts) do
    case PromptRunner.scaffold(source, cli_opts(opts)) do
      {:ok, paths} ->
        IO.puts(UI.green("Scaffolded PromptRunner files"))
        IO.puts("  prompts: #{paths.prompts_file}")
        IO.puts("  commits: #{paths.commit_messages_file}")
        IO.puts("  config: #{paths.config_file}")
        IO.puts("  runner: #{paths.runner_file}")
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_command(_command, _args, _opts) do
    handle_missing_input()
  end

  defp cli_opts(opts) do
    opts
    |> Keyword.put(:interface, :cli)
    |> maybe_put(:target, opts[:target])
    |> maybe_put(:project_dir, opts[:project_dir])
    |> maybe_put(:repo_override, opts[:repo_override])
    |> maybe_put(:provider, opts[:provider])
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:log_mode, opts[:log_mode])
    |> maybe_put(:log_meta, opts[:log_meta])
    |> maybe_put(:events_mode, opts[:events_mode])
    |> maybe_put(:tool_output, opts[:tool_output])
    |> maybe_put(:cli_confirmation, opts[:cli_confirmation])
    |> maybe_put(:require_cli_confirmation, opts[:require_cli_confirmation])
    |> maybe_put(:output, opts[:output])
    |> maybe_put(:state_dir, opts[:state_dir])
    |> maybe_put(:no_state, opts[:no_state])
    |> maybe_put(:runtime_store, opts[:runtime_store])
    |> maybe_put(:committer, opts[:committer])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_legacy(opts, remaining) do
    if opts[:config] == nil do
      handle_missing_config()
    else
      case PromptRunner.plan(opts[:config], cli_opts(opts)) do
        {:ok, plan} ->
          handle_runner_result(Runner.execute_plan(plan, opts, remaining))

        error ->
          handle_config_error(error)
      end
    end
  end

  defp print_plan_summary(plan) do
    IO.puts("")
    IO.puts(UI.bold("PromptRunner Plan"))
    IO.puts("Source: #{plan.source_root || inspect(plan.source)}")
    IO.puts("Prompts: #{length(plan.prompts)}")
    IO.puts("Provider: #{plan.config.llm_sdk}")
    IO.puts("Model: #{plan.config.model}")

    Enum.each(plan.prompts, fn prompt ->
      IO.puts("  #{prompt.num} - #{prompt.name}")
    end)

    IO.puts("")
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

  defp handle_runner_result({:error, reason}), do: handle_error(reason)

  @spec handle_error(term()) :: no_return()
  defp handle_error(errors) when is_list(errors) do
    handle_config_error({:error, errors})
  end

  defp handle_error(reason) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    System.halt(1)
  end

  @spec handle_config_error({:error, term()}) :: no_return()
  defp handle_config_error({:error, {:config_not_found, path}}) do
    IO.puts(UI.red("ERROR: Config file not found: #{path}"))
    System.halt(1)
  end

  defp handle_config_error({:error, {:invalid_llm_sdk, reason}}) do
    IO.puts(UI.red("ERROR: Invalid llm provider/sdk: #{inspect(reason)}"))
    System.halt(1)
  end

  defp handle_config_error({:error, errors}) when is_list(errors) do
    IO.puts(UI.red("ERROR: Config validation failed"))

    Enum.each(Enum.reverse(errors), fn error ->
      IO.puts("  - #{format_validation_error(error)}")
    end)

    System.halt(1)
  end

  defp handle_config_error({:error, reason}), do: handle_error(reason)

  @spec handle_missing_config() :: no_return()
  defp handle_missing_config do
    IO.puts(UI.red("ERROR: --config is required for legacy mode"))
    IO.puts("")
    IO.puts("Usage: mix run run_prompts.exs --config <config_file> [command] [options]")
    IO.puts("")
    IO.puts("Run with --help for more information.")
    System.halt(1)
  end

  @spec handle_missing_input() :: no_return()
  defp handle_missing_input do
    IO.puts(UI.red("ERROR: no command or source path provided"))
    IO.puts("")
    show_help()
    System.halt(1)
  end

  defp show_help do
    IO.puts("")
    IO.puts(UI.bold("PromptRunner"))
    IO.puts("")
    IO.puts("Convention-driven mode:")
    IO.puts("  prompt_runner list <prompt_dir> [--target /path/to/repo]")
    IO.puts("  prompt_runner run <prompt_dir> [--target /path/to/repo]")
    IO.puts("  prompt_runner validate <prompt_dir> [--target /path/to/repo]")
    IO.puts("  prompt_runner plan <prompt_dir> [--target /path/to/repo]")
    IO.puts("  prompt_runner scaffold <prompt_dir> [--output ./generated]")
    IO.puts("")
    IO.puts("Legacy mode:")
    IO.puts("  mix run run_prompts.exs --config runner_config.exs --list")
    IO.puts("  mix run run_prompts.exs --config runner_config.exs --run 01")
    IO.puts("")
  end

  defp format_validation_error({key, :missing_value}) do
    "#{format_validation_key(key)} is required"
  end

  defp format_validation_error({key, {:path_not_found, path}}) do
    "#{format_validation_key(key)} path not found: #{path}"
  end

  defp format_validation_error({key, {:not_a_directory, path}}) do
    "#{format_validation_key(key)} is not a directory: #{path}"
  end

  defp format_validation_error({key, {:not_git_repo, path}}) do
    "#{format_validation_key(key)} is not a git repository: #{path}"
  end

  defp format_validation_error({key, {:git_unavailable, path}}) do
    "#{format_validation_key(key)} could not be verified because git is not available: #{path}"
  end

  defp format_validation_error({key, {:invalid_timeout, timeout}}) do
    "#{format_validation_key(key)} is invalid: #{inspect(timeout)}"
  end

  defp format_validation_error({key, detail}) do
    "#{format_validation_key(key)}: #{inspect(detail)}"
  end

  defp format_validation_key({:target_repo, name}), do: "target repo #{name}"
  defp format_validation_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_validation_key(key), do: inspect(key)
end
