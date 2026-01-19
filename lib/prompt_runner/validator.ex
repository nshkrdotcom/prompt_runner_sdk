defmodule PromptRunner.Validator do
  @moduledoc false

  alias PromptRunner.CommitMessages
  alias PromptRunner.Prompts
  alias PromptRunner.UI

  @spec validate_all(PromptRunner.Config.t()) :: :ok | {:error, list()}
  def validate_all(config) do
    prompts = Prompts.list(config)
    commit_markers = CommitMessages.all_markers(config)
    print_header(config, prompts, commit_markers)

    errors = []
    errors = check_commit_messages(config, prompts, errors)
    errors = check_prompt_files(config, prompts, errors)
    errors = check_repo_refs(config, prompts, errors)

    print_summary(errors)
  end

  defp print_header(config, prompts, commit_markers) do
    IO.puts("")
    IO.puts(UI.bold("[VALIDATION] Comprehensive Configuration Check"))
    IO.puts(UI.blue(String.duplicate("=", 60)))

    IO.puts("")
    IO.puts(UI.yellow("1. Prompts file (#{config.prompts_file}):"))
    IO.puts("   #{length(prompts)} prompts defined")

    IO.puts("")
    IO.puts(UI.yellow("2. Commit messages file (#{config.commit_messages_file}):"))
    IO.puts("   #{length(commit_markers)} commit markers defined")

    IO.puts("")
    IO.puts(UI.yellow("3. Target repos configuration:"))
    print_target_repos(config)
  end

  defp print_target_repos(config) do
    case config.target_repos do
      nil ->
        IO.puts("   Single-repo mode (project_dir: #{config.project_dir})")

      repos when is_list(repos) ->
        IO.puts("   Multi-repo mode (#{length(repos)} repos):")
        Enum.each(repos, &print_repo_entry/1)
    end
  end

  defp print_repo_entry(repo) do
    status = if File.dir?(repo.path), do: UI.green("OK"), else: UI.red("ERR")
    default = if repo.default, do: " #{UI.dim("(default)")}", else: ""
    IO.puts("   #{status} #{repo.name}: #{repo.path}#{default}")
  end

  defp check_commit_messages(config, prompts, errors) do
    IO.puts("")
    IO.puts(UI.yellow("4. Commit message correlation check:"))

    Enum.reduce(prompts, errors, fn prompt, acc ->
      check_prompt_commit_messages(config, prompt, acc)
    end)
  end

  defp check_prompt_commit_messages(config, prompt, acc) do
    case prompt.target_repos do
      nil ->
        if CommitMessages.get_message(config, prompt.num) do
          IO.puts("   #{UI.green("OK")} Prompt #{prompt.num}: commit message found")
          acc
        else
          IO.puts("   #{UI.red("ERR")} Prompt #{prompt.num}: missing commit message")
          [{prompt.num, nil, "missing commit message"} | acc]
        end

      repos when is_list(repos) ->
        Enum.reduce(repos, acc, fn repo_name, inner_acc ->
          check_repo_commit_message(config, prompt, repo_name, inner_acc)
        end)
    end
  end

  defp check_repo_commit_message(config, prompt, repo_name, acc) do
    if CommitMessages.get_message(config, prompt.num, repo_name) do
      IO.puts("   #{UI.green("OK")} Prompt #{prompt.num}:#{repo_name}: commit message found")
      acc
    else
      IO.puts("   #{UI.red("ERR")} Prompt #{prompt.num}:#{repo_name}: missing commit message")
      [{prompt.num, repo_name, "missing commit message"} | acc]
    end
  end

  defp check_prompt_files(config, prompts, errors) do
    IO.puts("")
    IO.puts(UI.yellow("5. Prompt file existence check:"))

    Enum.reduce(prompts, errors, fn prompt, acc ->
      prompt_path = Path.join(config.config_dir, prompt.file)

      if File.exists?(prompt_path) do
        IO.puts("   #{UI.green("OK")} #{prompt.num}: #{prompt.file}")
        acc
      else
        IO.puts("   #{UI.red("ERR")} #{prompt.num}: #{prompt.file} not found")
        [{prompt.num, nil, "prompt file not found: #{prompt.file}"} | acc]
      end
    end)
  end

  defp check_repo_refs(config, prompts, errors) do
    IO.puts("")
    IO.puts(UI.yellow("6. Target repo reference check:"))

    configured_repos =
      case config.target_repos do
        nil -> []
        repos -> Enum.map(repos, & &1.name)
      end

    Enum.reduce(prompts, errors, fn prompt, acc ->
      check_prompt_repo_refs(prompt, configured_repos, acc)
    end)
  end

  defp check_prompt_repo_refs(prompt, configured_repos, acc) do
    case prompt.target_repos do
      nil ->
        acc

      repos when is_list(repos) ->
        Enum.reduce(repos, acc, fn repo_name, inner_acc ->
          check_repo_ref(prompt, repo_name, configured_repos, inner_acc)
        end)
    end
  end

  defp check_repo_ref(prompt, repo_name, configured_repos, acc) do
    if repo_name in configured_repos do
      IO.puts("   #{UI.green("OK")} Prompt #{prompt.num} -> #{repo_name}")
      acc
    else
      IO.puts("   #{UI.red("ERR")} Prompt #{prompt.num} -> #{repo_name}: not configured")
      [{prompt.num, repo_name, "repo not configured in target_repos"} | acc]
    end
  end

  defp print_summary(errors) do
    IO.puts("")
    IO.puts(UI.blue(String.duplicate("=", 60)))

    if errors == [] do
      IO.puts(UI.green("All validation checks passed"))
      :ok
    else
      IO.puts(UI.red("#{length(errors)} validation error(s) found:"))

      Enum.each(Enum.reverse(errors), fn
        {num, nil, msg} -> IO.puts("  - Prompt #{num}: #{msg}")
        {num, repo, msg} -> IO.puts("  - Prompt #{num}:#{repo}: #{msg}")
      end)

      {:error, errors}
    end
  end
end
