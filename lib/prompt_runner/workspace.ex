defmodule PromptRunner.Workspace do
  @moduledoc """
  Operator-owned workspace planning, materialization, and readiness.

  A workspace maps logical packet repositories onto full independent clones.
  Runtime state is kept under the current operator's state root, never beneath
  the packet or a shared source checkout.
  """

  alias PromptRunner.Config
  alias PromptRunner.Control.Store
  alias PromptRunner.PathRewriter
  alias PromptRunner.Plan, as: RunnerPlan
  alias PromptRunner.RuntimeStore.FileStore
  alias PromptRunner.Workspace.{Doctor, LegacyStateImporter, Manifest, Materializer, Plan, Status}

  @doc "Deterministic transient user-service unit for a workspace."
  @spec service_unit(String.t()) :: String.t()
  def service_unit(id) when is_binary(id) do
    digest = :crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    prefix = id |> String.slice(0, 80) |> String.trim_trailing("-")
    "prompt-runner-#{prefix}-#{digest}.service"
  end

  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(manifest_path, opts \\ []),
    do: Status.read(manifest_path, opts)

  @spec plan(String.t(), String.t(), keyword()) ::
          {:ok, %{workspace: Plan.t(), runner: RunnerPlan.t(), packet_root: String.t()}}
          | {:error, term()}
  def plan(manifest_path, packet_path, opts \\ []) do
    source_packet_root = source_packet_root(packet_path)

    with {:ok, manifest} <- Manifest.load(manifest_path),
         workspace_plan = Plan.build(manifest),
         {:ok, packet_root} <- mapped_packet_root(source_packet_root, workspace_plan),
         state_dir = Path.join(workspace_plan.runtime_root, "packet"),
         {:ok, runner_plan} <-
           PromptRunner.plan(
             packet_root,
             Keyword.merge([interface: :cli, state_dir: state_dir], opts)
           ),
         :ok <- validate_repo_coverage(runner_plan, workspace_plan) do
      runner_plan = overlay_runner_plan(runner_plan, workspace_plan, state_dir)
      {:ok, %{workspace: workspace_plan, runner: runner_plan, packet_root: packet_root}}
    end
  end

  @doc "The operator-owned control-store root for a workspace manifest."
  @spec control_root(String.t()) :: {:ok, Store.root()} | {:error, term()}
  def control_root(manifest_path) when is_binary(manifest_path) do
    with {:ok, manifest} <- Manifest.load(manifest_path) do
      state_dir = manifest |> Plan.build() |> Map.fetch!(:runtime_root) |> Path.join("packet")
      {:ok, Store.state_root(state_dir)}
    end
  end

  @doc "Resolves a packet beneath a declared source repository into its independent clone."
  @spec packet_root(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def packet_root(manifest_path, packet_path)
      when is_binary(manifest_path) and is_binary(packet_path) do
    source_packet_root = source_packet_root(packet_path)

    with {:ok, manifest} <- Manifest.load(manifest_path) do
      mapped_packet_root(source_packet_root, Plan.build(manifest))
    end
  end

  @spec prepare(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(manifest_path, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(manifest_path) do
      manifest |> Plan.build() |> Materializer.prepare(opts)
    end
  end

  @spec doctor(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def doctor(manifest_path, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(manifest_path) do
      manifest |> Plan.build() |> Doctor.check(opts)
    end
  end

  @doc "Imports completed legacy progress into an empty operator workspace."
  @spec import_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_state(manifest_path, packet_path, opts \\ []) do
    LegacyStateImporter.import(manifest_path, packet_path, opts)
  end

  defp overlay_runner_plan(runner_plan, workspace_plan, state_dir) do
    source_repos = Map.new(runner_plan.config.target_repos, &{to_string(&1.name), &1.path})

    runner_plan =
      RunnerPlan.with_overrides(runner_plan,
        repo_override: Plan.repo_overrides(workspace_plan)
      )

    workspace_repos = Map.new(runner_plan.config.target_repos, &{to_string(&1.name), &1.path})

    path_rewrites =
      Map.new(source_repos, fn {name, source_path} ->
        {source_path, Map.fetch!(workspace_repos, name)}
      end)

    progress_file = Path.join(state_dir, "progress.log")
    log_dir = Path.join(state_dir, "logs")

    %Config{} = current_config = runner_plan.config

    config = %Config{
      current_config
      | project_dir: PathRewriter.text(current_config.project_dir, path_rewrites),
        progress_file: progress_file,
        log_dir: log_dir
    }

    artifacts = Map.new(workspace_plan.artifacts, fn {id, artifact} -> {id, artifact.path} end)

    options =
      runner_plan.options
      |> Map.put(:failure_policy, workspace_plan.manifest.failure_policy)
      |> Map.put(:artifacts, artifacts)
      |> Map.put(:path_rewrites, path_rewrites)

    %{
      runner_plan
      | config: config,
        options: options,
        state_dir: state_dir,
        runtime_store: {FileStore, %{progress_file: progress_file, log_dir: log_dir}}
    }
  end

  defp validate_repo_coverage(runner_plan, workspace_plan) do
    packet_names = runner_plan.config.target_repos |> List.wrap() |> Enum.map(& &1.name)
    workspace_names = Map.keys(workspace_plan.repositories)

    case packet_names -- workspace_names do
      [] -> :ok
      missing -> {:error, {:workspace_missing_packet_repositories, Enum.sort(missing)}}
    end
  end

  defp source_packet_root(path) do
    path = Path.expand(path)
    if File.dir?(path), do: path, else: Path.dirname(path)
  end

  defp mapped_packet_root(source_packet_root, %Plan{} = workspace_plan) do
    candidates =
      workspace_plan.repositories
      |> Enum.flat_map(fn {_name, repo} -> packet_candidate(source_packet_root, repo) end)

    case Enum.max_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil ->
        {:ok, source_packet_root}

      {_length, source, destination} ->
        mapped = Path.expand(Path.relative_to(source_packet_root, source), destination)

        if File.dir?(mapped) do
          {:ok, mapped}
        else
          {:error, {:workspace_packet_missing, source_packet_root, mapped}}
        end
    end
  end

  defp packet_candidate(source_packet_root, %{source: source, path: destination})
       when is_binary(source) do
    source = Path.expand(source)

    if within?(source_packet_root, source),
      do: [{byte_size(source), source, destination}],
      else: []
  end

  defp packet_candidate(_source_packet_root, _repo), do: []

  defp within?(path, root) do
    relative = Path.relative_to(Path.expand(path), Path.expand(root))
    relative == "." or not (relative == ".." or String.starts_with?(relative, "../"))
  end
end
