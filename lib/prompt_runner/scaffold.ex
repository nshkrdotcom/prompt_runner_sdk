defmodule PromptRunner.Scaffold do
  @moduledoc """
  Generates legacy PromptRunner files from a convention-based prompt directory.
  """

  alias PromptRunner.LLMFacade
  alias PromptRunner.Plan

  @provider_dep_specs %{
    claude: {:claude_agent_sdk, "~> 0.17.0"},
    codex: {:codex_sdk, "~> 0.16.1"},
    gemini: {:gemini_cli_sdk, "~> 0.2.0"},
    amp: {:amp_sdk, "~> 0.5.0"}
  }
  @provider_dep_order [:claude, :codex, :gemini, :amp]

  @spec write(Plan.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(%Plan{} = plan, opts) do
    output_dir = opts[:output] || plan.source_root || File.cwd!()
    File.mkdir_p!(output_dir)

    prompts_path = Path.join(output_dir, "prompts.txt")
    commits_path = Path.join(output_dir, "commit-messages.txt")
    config_path = Path.join(output_dir, "runner_config.exs")
    runner_path = Path.join(output_dir, "run_prompts.exs")

    File.write!(prompts_path, prompts_content(plan))
    File.write!(commits_path, commit_messages_content(plan))
    File.write!(config_path, config_content(plan, output_dir))
    File.write!(runner_path, runner_content(plan))
    File.chmod!(runner_path, 0o755)

    {:ok,
     %{
       prompts_file: prompts_path,
       commit_messages_file: commits_path,
       config_file: config_path,
       runner_file: runner_path
     }}
  end

  defp prompts_content(plan) do
    Enum.map_join(plan.prompts, "\n", fn prompt ->
      [
        prompt.num,
        prompt.phase,
        prompt.sp,
        prompt.name,
        prompt.file || "#{prompt.num}.prompt.md"
      ]
      |> Enum.join("|")
    end) <> "\n"
  end

  defp commit_messages_content(plan) do
    body =
      Enum.map_join(plan.prompts, "\n\n", fn prompt ->
        message =
          Map.get(plan.commit_messages, {prompt.num, nil}) ||
            prompt.commit_message ||
            "feat: #{prompt.name}"

        "=== COMMIT #{prompt.num} ===\n#{message}"
      end)

    body <> "\n"
  end

  defp config_content(plan, output_dir) do
    config = plan.config

    project_dir =
      case config.target_repos do
        [%{path: path} | _] -> path
        _ -> config.project_dir || output_dir
      end

    """
    %{
      project_dir: "#{project_dir}",
      prompts_file: "prompts.txt",
      commit_messages_file: "commit-messages.txt",
      progress_file: ".progress",
      log_dir: "logs",
      model: "#{config.model}",
      llm: %{provider: "#{config.llm_sdk}"}
    }
    """
  end

  defp runner_content(plan) do
    install_entries =
      [~s({:prompt_runner_sdk, "~> 0.5.1"}) | provider_dep_lines(plan)]
      |> Enum.map_join(",\n", &"      #{&1}")

    """
    #!/usr/bin/env elixir

    Application.ensure_all_started(:inets)

    Mix.install([
    #{install_entries}
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
    """
  end

  defp provider_dep_lines(%Plan{} = plan) do
    plan
    |> selected_providers()
    |> Enum.map(fn provider ->
      {package, version} = Map.fetch!(@provider_dep_specs, provider)
      ~s({#{inspect(package)}, "#{version}"})
    end)
  end

  defp selected_providers(%Plan{} = plan) do
    base_provider = normalize_provider(plan.config.llm_sdk)

    override_providers =
      (plan.config.prompt_overrides || %{})
      |> Map.values()
      |> Enum.map(&provider_value/1)
      |> Enum.map(&normalize_provider/1)

    [base_provider | override_providers]
    |> Enum.filter(&(&1 in @provider_dep_order))
    |> Enum.uniq()
    |> Enum.sort_by(&provider_order/1)
  end

  defp provider_value(override) when is_map(override) do
    Map.get(override, :provider) ||
      Map.get(override, "provider") ||
      Map.get(override, :sdk) ||
      Map.get(override, "sdk")
  end

  defp provider_value(_override), do: nil

  defp normalize_provider(value) do
    case LLMFacade.normalize_provider(value) do
      provider when is_atom(provider) -> provider
      {:error, _reason} -> nil
    end
  end

  defp provider_order(provider), do: Enum.find_index(@provider_dep_order, &(&1 == provider))
end
