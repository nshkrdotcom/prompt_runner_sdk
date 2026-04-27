defmodule PromptRunner.Preflight do
  @moduledoc false

  alias PromptRunner.Plan
  alias PromptRunner.Validator

  @spec plan_report(Plan.t()) :: map()
  def plan_report(%Plan{} = plan) do
    repo_checks = repo_checks(plan.config.target_repos, plan.config.project_dir)
    errors = readiness_errors(repo_checks)

    %{
      source_root: plan.source_root,
      input_type: plan.input_type,
      interface: plan.interface,
      provider: plan.config.llm_sdk,
      model: plan.config.model,
      project_dir: plan.config.project_dir,
      repos: repo_checks,
      readiness_errors: errors,
      runtime_ready?: errors == []
    }
  end

  @spec check_plan(Plan.t()) :: {:ok, map()} | {:error, {:preflight_failed, map()}}
  def check_plan(%Plan{interface: :legacy, config: config} = plan) do
    case Validator.validate_all(config) do
      :ok ->
        {:ok,
         %{
           source_root: plan.source_root,
           input_type: plan.input_type,
           interface: plan.interface,
           provider: plan.config.llm_sdk,
           model: plan.config.model,
           project_dir: plan.config.project_dir,
           repos: [],
           readiness_errors: [],
           runtime_ready?: true
         }}

      {:error, errors} ->
        report = %{
          source_root: plan.source_root,
          input_type: plan.input_type,
          interface: plan.interface,
          provider: plan.config.llm_sdk,
          model: plan.config.model,
          project_dir: plan.config.project_dir,
          repos: [],
          readiness_errors: Enum.map(errors, &legacy_error/1),
          runtime_ready?: false
        }

        {:error, {:preflight_failed, report}}
    end
  end

  def check_plan(%Plan{} = plan) do
    report = plan_report(plan)
    if report.runtime_ready?, do: {:ok, report}, else: {:error, {:preflight_failed, report}}
  end

  @spec repo_checks([map()] | nil, String.t() | nil) :: [map()]
  def repo_checks(repos, _project_dir) when is_list(repos) and repos != [] do
    Enum.map(repos, &repo_check/1)
  end

  def repo_checks(_repos, project_dir) when is_binary(project_dir) do
    [repo_check(%{name: "default", path: project_dir, default: true})]
  end

  def repo_checks(_repos, _project_dir), do: []

  @spec readiness_errors([map()]) :: [map()]
  def readiness_errors(repo_checks) do
    Enum.flat_map(repo_checks, fn repo ->
      repo
      |> Map.get(:errors, [])
      |> Enum.map(fn error ->
        error
        |> Map.put(:scope, "repo")
        |> Map.put(:name, repo.name)
        |> Map.put(:path, repo.path)
      end)
    end)
  end

  defp repo_check(repo) when is_map(repo) do
    name = repo[:name] || repo["name"] || "default"
    path = repo[:path] || repo["path"]

    base = %{
      name: name,
      path: path,
      default: repo[:default] || repo["default"] || false,
      exists?: false,
      directory?: false,
      git?: false,
      ready?: false,
      errors: []
    }

    cond do
      path in [nil, ""] ->
        %{base | errors: [%{kind: "missing_path"}]}

      not File.exists?(path) ->
        %{base | path: path, errors: [%{kind: "path_not_found"}]}

      not File.dir?(path) ->
        %{base | exists?: true, errors: [%{kind: "not_a_directory"}]}

      true ->
        case git_repo_status(path) do
          :ok ->
            %{base | exists?: true, directory?: true, git?: true, ready?: true}

          {:error, reason} ->
            %{base | exists?: true, directory?: true, errors: [%{kind: Atom.to_string(reason)}]}
        end
    end
  end

  defp repo_check(_repo), do: repo_check(%{name: "unnamed", path: nil})

  defp git_repo_status(path) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_unavailable}

      git ->
        case System.cmd(git, ["-C", path, "rev-parse", "--is-inside-work-tree"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            if String.trim(output) == "true", do: :ok, else: {:error, :not_git_repo}

          {_output, _exit_code} ->
            {:error, :not_git_repo}
        end
    end
  end

  defp legacy_error({key, reason}) do
    %{scope: "legacy_config", key: inspect(key), kind: inspect(reason)}
  end

  defp legacy_error(reason), do: %{scope: "legacy_config", kind: inspect(reason)}
end
