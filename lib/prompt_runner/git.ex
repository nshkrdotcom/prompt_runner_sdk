defmodule PromptRunner.Git do
  @moduledoc false

  alias PromptRunner.CommitMessages
  alias PromptRunner.UI

  @spec commit_multi_repo(PromptRunner.Config.t(), String.t(), list({String.t(), String.t()})) ::
          list({String.t(), term()})
  def commit_multi_repo(config, num, target_repos) do
    Enum.map(target_repos, fn {repo_name, repo_path} ->
      msg = CommitMessages.get_message(config, num, repo_name)

      unless msg do
        raise "Commit message not found for prompt #{num}:#{repo_name}"
      end

      IO.puts("")
      IO.puts("#{UI.yellow("Checking")} #{repo_name} (#{repo_path})...")
      result = commit_repo(repo_path, msg, num, repo_name)
      {repo_name, result}
    end)
  end

  @spec commit_single_repo(PromptRunner.Config.t(), String.t()) ::
          {:ok, String.t()} | {:skip, atom()} | {:error, atom()}
  def commit_single_repo(config, num) do
    msg = CommitMessages.get_message(config, num)

    unless msg do
      raise "Commit message not found for prompt #{num}"
    end

    commit_repo(config.project_dir, msg, num, "default")
  end

  @spec commit_repo(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:skip, atom()} | {:error, atom()}
  def commit_repo(project_dir, msg, num, repo_name) do
    {status, exit_status} = System.cmd("git", ["status", "--porcelain"], cd: project_dir)

    cond do
      exit_status != 0 ->
        IO.puts(UI.red("ERROR: git status failed for #{repo_name}"))
        {:error, :git_status_failed}

      String.trim(status) == "" ->
        IO.puts(UI.dim("No changes in #{repo_name}"))
        {:skip, :no_changes}

      true ->
        IO.puts(UI.yellow("Committing to #{repo_name}..."))

        {_, 0} = System.cmd("git", ["add", "-A"], cd: project_dir)

        tmp_dir = System.tmp_dir!()
        tmp_id = System.unique_integer([:positive])
        tmp_path = Path.join(tmp_dir, "prompt-#{num}-#{repo_name}-commit-msg-#{tmp_id}.txt")
        File.write!(tmp_path, msg <> "\n")

        {_, exit_code} = System.cmd("git", ["commit", "--file", tmp_path], cd: project_dir)
        File.rm(tmp_path)

        if exit_code == 0 do
          {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: project_dir)
          short = sha |> String.trim() |> String.slice(0, 8)
          IO.puts(UI.green("Committed to #{repo_name}: #{short}"))
          {:ok, String.trim(sha)}
        else
          IO.puts(UI.red("ERROR: Git commit failed for #{repo_name}"))
          {:error, :commit_failed}
        end
    end
  end
end
