defmodule PromptRunner.Workspace.Materializer do
  @moduledoc "Materializes full, independent, operator-owned Git clones."

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias PromptRunner.Workspace.ArtifactBuilder
  alias PromptRunner.Workspace.Plan
  alias PromptRunner.Workspace.Reference

  @clone_timeout_ms 600_000

  @spec prepare(Plan.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%Plan{} = plan, opts \\ []) do
    with :ok <- File.mkdir_p(plan.repos_root),
         {:ok, repos} <- prepare_repositories(plan, opts),
         {:ok, artifacts} <- ArtifactBuilder.prepare(plan, opts),
         :ok <- write_lock(plan, repos, artifacts),
         :ok <- Reference.register(plan.manifest.id, plan.manifest.path, plan.lock_path) do
      {:ok,
       %{
         workspace: plan.manifest.id,
         lock_path: plan.lock_path,
         repositories: repos,
         artifacts: artifacts
       }}
    end
  end

  defp prepare_repositories(plan, opts) do
    plan.repositories
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {name, repo}, {:ok, acc} ->
      case prepare_repository(repo, plan.repos_root, opts) do
        {:ok, record} -> {:cont, {:ok, Map.put(acc, name, record)}}
        {:error, reason} -> {:halt, {:error, {:repository_prepare_failed, name, reason}}}
      end
    end)
  end

  defp prepare_repository(repo, repos_root, opts) do
    if File.exists?(repo.path) do
      update_existing(repo, opts)
    else
      clone_repository(repo, repos_root, opts)
    end
  end

  defp update_existing(repo, opts) do
    with {:ok, _record} <- inspect_existing(repo, opts),
         {:ok, ""} <- git(["status", "--porcelain"], repo.path, opts),
         {:ok, _output} <- git(["fetch", "--prune", "origin"], repo.path, opts),
         {:ok, _output} <- git(["checkout", repo.ref], repo.path, opts),
         :ok <- fast_forward_remote_ref(repo, opts) do
      inspect_existing(repo, opts)
    else
      {:ok, dirty} -> {:error, {:dirty_workspace_repository, String.trim(dirty)}}
      {:error, _reason} = error -> error
    end
  end

  defp fast_forward_remote_ref(repo, opts) do
    remote_ref = "refs/remotes/origin/#{repo.ref}"

    case git(["rev-parse", "--verify", remote_ref], repo.path, opts) do
      {:ok, _sha} ->
        case git(["merge", "--ff-only", remote_ref], repo.path, opts) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:workspace_ref_diverged, repo.ref, reason}}
        end

      {:error, _reason} ->
        # A tag or exact commit has no remote-tracking branch. Checkout already
        # resolved it, so there is nothing to fast-forward.
        :ok
    end
  end

  defp clone_repository(repo, repos_root, opts) do
    sources =
      [repo.source, repo.remote]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(sources, {:error, {:clone_sources_failed, []}}, fn source, result ->
      case clone_from_source(repo, repos_root, source, opts) do
        {:ok, _record} = success ->
          {:halt, success}

        {:error, reason} ->
          {:error, {:clone_sources_failed, failures}} = result
          {:cont, {:error, {:clone_sources_failed, failures ++ [{source, reason}]}}}
      end
    end)
  end

  defp clone_from_source(repo, repos_root, source, opts) do
    temp = Path.join(repos_root, ".#{repo.name}.tmp-#{System.unique_integer([:positive])}")
    clone_args = ["clone", "--no-hardlinks", "--no-checkout", source, temp]

    result =
      with {:ok, _output} <- git(clone_args, repos_root, opts),
           {:ok, _output} <- git(["remote", "set-url", "origin", repo.remote], temp, opts),
           {:ok, _output} <- git(["checkout", repo.ref], temp, opts),
           :ok <- reject_shared_git_metadata(temp),
           :ok <- File.rename(temp, repo.path) do
        inspect_existing(repo, opts)
      end

    if File.exists?(temp), do: File.rm_rf(temp)
    result
  end

  defp inspect_existing(repo, opts) do
    with true <- File.dir?(repo.path) || {:error, :not_a_directory},
         true <- File.dir?(Path.join(repo.path, ".git")) || {:error, :not_an_independent_clone},
         :ok <- reject_shared_git_metadata(repo.path),
         {:ok, remote} <- git(["remote", "get-url", "origin"], repo.path, opts),
         true <-
           String.trim(remote) == repo.remote || {:error, {:wrong_remote, String.trim(remote)}},
         {:ok, head} <- git(["rev-parse", "HEAD"], repo.path, opts) do
      {:ok,
       %{
         path: repo.path,
         remote: repo.remote,
         ref: repo.ref,
         commit: String.trim(head),
         independent: true
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp reject_shared_git_metadata(path) do
    alternates = Path.join([path, ".git", "objects", "info", "alternates"])
    if File.exists?(alternates), do: {:error, :shared_git_alternates}, else: :ok
  end

  defp git(args, cwd, opts) do
    case System.find_executable("git") do
      nil -> {:error, :git_not_found}
      git -> run_git(git, args, cwd, opts)
    end
  end

  defp run_git(git, args, cwd, opts) do
    invocation = Command.new(git, args, cwd: cwd)
    timeout = Keyword.get(opts, :timeout_ms, @clone_timeout_ms)

    case Command.run(invocation, timeout: timeout, stderr: :stdout) do
      {:ok, %RunResult{} = result} -> git_result(result)
      {:error, error} -> {:error, {:git_fault, Exception.message(error)}}
    end
  end

  defp git_result(%RunResult{} = result) do
    if RunResult.success?(result),
      do: {:ok, result.output},
      else: {:error, {:git_exit, result.exit.code, String.trim(result.output)}}
  end

  defp write_lock(plan, repositories, artifacts) do
    lock = %{
      schema: "prompt_runner.workspace.lock/v1",
      workspace: plan.manifest.id,
      manifest: plan.manifest.path,
      runner: %{version: PromptRunner.version(), capabilities: PromptRunner.Capabilities.list()},
      repositories: repositories,
      artifacts: artifacts,
      written_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    atomic_write(plan.lock_path, Jason.encode!(lock, pretty: true))
  end

  defp atomic_write(path, contents) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, contents, [:binary, :sync]),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, _reason} = error -> error
      end
    after
      _ = File.rm(temp)
    end
  end
end
