defmodule PromptRunner.Committer.GitCommitter do
  @moduledoc """
  Committer that applies git commits to one or more target repositories.
  """

  @behaviour PromptRunner.Committer

  alias PromptRunner.Git
  alias PromptRunner.RepoTargets

  @impl true
  def commit(config, prompt, _llm, _opts) do
    target_repos = resolve_target_repos(config, prompt)

    if length(target_repos) > 1 do
      Git.commit_multi_repo(config, prompt.num, target_repos)
    else
      [{repo_name, repo_path}] = target_repos
      Git.commit_single_repo(config, prompt.num, repo_name, repo_path)
    end
  end

  defp resolve_target_repos(config, prompt) do
    case prompt.target_repos do
      nil ->
        case get_default_repo(config) do
          %{name: name, path: path} -> [{name, path}]
          _ -> [{"default", config.project_dir}]
        end

      repos when is_list(repos) ->
        unless is_list(config.target_repos) do
          raise "Prompt #{prompt.num} defines target_repos but config.target_repos is not configured"
        end

        resolved_repos =
          repos
          |> RepoTargets.expand!(config.repo_groups || %{})
          |> List.wrap()

        if resolved_repos == [] do
          raise "Prompt #{prompt.num} did not resolve any target repos from: #{Enum.join(repos, ", ")}"
        end

        Enum.map(resolved_repos, &resolve_repo_name_path(&1, config, prompt))
    end
  end

  defp resolve_repo_name_path(repo_name, config, prompt) do
    case get_repo_path(config, repo_name) do
      nil -> raise "Repo not configured for prompt #{prompt.num}: #{repo_name}"
      path -> {repo_name, path}
    end
  end

  defp get_repo_path(config, repo_name) do
    case config.target_repos do
      repos when is_list(repos) ->
        case Enum.find(repos, &(&1.name == repo_name)) do
          %{path: path} -> path
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_default_repo(config) do
    case config.target_repos do
      repos when is_list(repos) ->
        Enum.find(repos, &(&1.default == true)) || List.first(repos)

      _ ->
        nil
    end
  end
end
