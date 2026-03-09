defmodule PromptRunner.Scaffold do
  @moduledoc """
  Generates legacy PromptRunner files from a convention-based prompt directory.
  """

  alias PromptRunner.Plan

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
    File.write!(runner_path, runner_content())
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
    project_dir =
      case plan.target_repos do
        [%{path: path} | _] -> path
        _ -> plan.project_dir || output_dir
      end

    """
    %{
      project_dir: "#{project_dir}",
      prompts_file: "prompts.txt",
      commit_messages_file: "commit-messages.txt",
      progress_file: ".progress",
      log_dir: "logs",
      model: "#{plan.model}",
      llm: %{provider: "#{plan.llm_sdk}"}
    }
    """
  end

  defp runner_content do
    """
    #!/usr/bin/env elixir

    Application.ensure_all_started(:inets)

    Mix.install([
      {:prompt_runner_sdk, "~> 0.5.0"},
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
    """
  end
end
