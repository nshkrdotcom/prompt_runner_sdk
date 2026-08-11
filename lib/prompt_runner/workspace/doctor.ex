defmodule PromptRunner.Workspace.Doctor do
  @moduledoc "Read-only readiness checks for an operator-owned workspace."

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias ExecutionPlane.Process.Containment.SystemdUser
  alias PromptRunner.Workspace.Plan
  alias PromptRunner.Workspace.ToolchainDoctor

  @spec check(Plan.t(), keyword()) :: {:ok, map()}
  def check(%Plan{} = plan, opts \\ []) do
    repo_reports =
      plan.repositories
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, repo} -> {name, check_repo(repo, opts)} end)
      |> Map.new()

    capability_report = capability_report(plan)
    containment = containment_report(plan, opts)
    toolchains = ToolchainDoctor.check(plan, opts)
    artifacts = artifact_report(plan, opts)

    ready? =
      Enum.all?(repo_reports, fn {_name, report} -> report.ready? end) and
        capability_report.ready? and containment.ready? and
        toolchains.ready? and artifacts.ready?

    report = %{
      schema: "prompt_runner.workspace.doctor/v1",
      workspace: plan.manifest.id,
      ready?: ready?,
      repositories: repo_reports,
      capabilities: capability_report,
      containment: containment,
      toolchains: toolchains,
      artifacts: artifacts,
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, json_safe(report)}
  end

  defp check_repo(repo, opts) do
    independent? = File.dir?(Path.join(repo.path, ".git"))
    symlink? = match?({:ok, %File.Stat{type: :symlink}}, File.lstat(repo.path))
    owner = owner(repo.path)
    current_owner = current_uid(opts)
    owner_ok? = is_integer(owner) and owner == current_owner
    remote = git_value(repo.path, ["remote", "get-url", "origin"], opts)
    dirty = git_value(repo.path, ["status", "--porcelain"], opts)
    head = git_value(repo.path, ["rev-parse", "HEAD"], opts)

    warnings =
      case dirty do
        {:ok, ""} -> []
        {:ok, paths} -> [{:dirty_resumable_workspace, paths}]
        _other -> []
      end

    errors =
      []
      |> maybe_error(not File.dir?(repo.path), :missing)
      |> maybe_error(not independent?, :not_independent_clone)
      |> maybe_error(symlink?, :symlink)
      |> maybe_error(not owner_ok?, {:wrong_owner, owner, current_owner})
      |> maybe_error(remote != {:ok, repo.remote}, {:wrong_or_unreadable_remote, remote})
      |> maybe_error(not match?({:ok, _}, dirty), {:git_status_unreadable, dirty})
      |> maybe_error(not match?({:ok, _}, head), {:head_unreadable, head})

    %{
      ready?: errors == [],
      path: repo.path,
      remote: remote,
      head: head,
      owner_uid: owner,
      independent_clone?: independent?,
      warnings: warnings,
      errors: Enum.reverse(errors)
    }
  end

  defp capability_report(plan) do
    available = PromptRunner.Capabilities.list()
    missing = plan.manifest.required_capabilities -- available
    requirement = plan.manifest.prompt_runner_requirement
    version_ok? = version_matches?(PromptRunner.version(), requirement)

    %{
      ready?: missing == [] and version_ok?,
      runner_version: PromptRunner.version(),
      requirement: requirement,
      version_ok?: version_ok?,
      missing: missing,
      available: available
    }
  end

  defp containment_report(%{manifest: %{containment: "systemd_user"}}, opts) do
    available? = SystemdUser.available?(opts)
    %{ready?: available?, requested: "systemd_user", strength: :strict, available?: available?}
  end

  defp containment_report(%{manifest: %{containment: containment}}, _opts) do
    %{ready?: false, requested: containment, strength: :unknown, available?: false}
  end

  defp version_matches?(_version, nil), do: true

  defp version_matches?(version, requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, parsed} -> Version.match?(version, parsed)
      :error -> false
    end
  end

  defp git_value(path, args, opts) do
    git = System.find_executable("git")

    if File.dir?(path) and is_binary(git) do
      run_git_value(git, path, args, opts)
    else
      {:error, if(is_nil(git), do: :git_not_found, else: :missing)}
    end
  end

  defp run_git_value(git, path, args, opts) do
    invocation = Command.new(git, args, cwd: path)

    case Command.run(invocation,
           timeout: Keyword.get(opts, :timeout_ms, 10_000),
           stderr: :stdout
         ) do
      {:ok, %RunResult{} = result} -> git_value_result(result)
      {:error, error} -> {:error, {:fault, Exception.message(error)}}
    end
  end

  defp git_value_result(%RunResult{} = result) do
    if RunResult.success?(result),
      do: {:ok, String.trim(result.output)},
      else: {:error, {:exit, result.exit.code, String.trim(result.output)}}
  end

  defp owner(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.uid
      {:error, _reason} -> nil
    end
  end

  defp current_uid(opts) do
    case Keyword.get(opts, :current_uid) do
      uid when is_integer(uid) -> uid
      _other -> owner(System.user_home!())
    end
  end

  defp maybe_error(errors, true, error), do: [error | errors]
  defp maybe_error(errors, false, _error), do: errors

  defp artifact_report(plan, opts) do
    current_owner = current_uid(opts)

    items =
      Map.new(plan.artifacts, fn {id, artifact} ->
        executable? = File.regular?(artifact.path) and executable?(artifact.path)
        artifact_owner = owner(artifact.path)
        ready? = executable? and artifact_owner == current_owner

        {id,
         %{
           ready?: ready?,
           path: artifact.path,
           executable?: executable?,
           owner_uid: artifact_owner,
           error:
             if(ready?,
               do: nil,
               else: {:artifact_not_ready, executable?, artifact_owner, current_owner}
             )
         }}
      end)

    %{ready?: Enum.all?(items, fn {_id, report} -> report.ready? end), items: items}
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end

  defp json_safe(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&json_safe/1)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value), do: value
end
