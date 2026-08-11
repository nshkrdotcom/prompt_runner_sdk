defmodule PromptRunner.Workspace.Manifest do
  @moduledoc """
  Strict, versioned operator-workspace manifest.

  Runtime repository paths are logical. They materialize beneath the current
  operator's data root and never point at a different operator's writable
  checkout.
  """

  @schema "prompt_runner.workspace/v1"
  @root_keys ~w(schema id requires repositories operator commits failure_policy contracts)
  @repo_keys ~w(remote ref source)
  @operator_keys ~w(workspace_root runtime_root containment)
  @requires_keys ~w(prompt_runner capabilities)
  @commits_keys ~w(mode push)
  @contracts_keys ~w(modules artifacts)
  @artifact_keys ~w(id repo project type)

  @enforce_keys [:path, :id, :repositories]
  defstruct [
    :path,
    :id,
    :repositories,
    :workspace_root,
    :runtime_root,
    :containment,
    :prompt_runner_requirement,
    :required_capabilities,
    :commit_mode,
    :push_policy,
    :failure_policy,
    contract_artifacts: [],
    contract_modules: []
  ]

  @type repository :: %{
          name: String.t(),
          remote: String.t(),
          ref: String.t(),
          source: String.t() | nil
        }

  @type t :: %__MODULE__{
          path: String.t(),
          id: String.t(),
          repositories: %{required(String.t()) => repository()},
          workspace_root: String.t(),
          runtime_root: String.t(),
          containment: String.t(),
          prompt_runner_requirement: String.t() | nil,
          required_capabilities: [String.t()],
          commit_mode: String.t(),
          push_policy: String.t(),
          failure_policy: String.t(),
          contract_artifacts: [map()],
          contract_modules: [String.t()]
        }

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, raw} <- YamlElixir.read_from_file(path),
         true <- is_map(raw) || {:error, :workspace_manifest_not_a_map},
         raw <- stringify_keys(raw),
         :ok <- reject_unknown(raw, @root_keys, []),
         :ok <- require_schema(raw),
         {:ok, id} <- required_string(raw, "id", []),
         :ok <- validate_id(id),
         {:ok, repositories} <- parse_repositories(raw["repositories"], Path.dirname(path)),
         {:ok, manifest} <- build(path, id, repositories, raw) do
      {:ok, manifest}
    else
      {:error, _reason} = error -> error
      false -> {:error, :workspace_manifest_not_a_map}
    end
  end

  defp build(path, id, repositories, raw) do
    requires = stringify_keys(raw["requires"] || %{})
    operator = stringify_keys(raw["operator"] || %{})
    commits = stringify_keys(raw["commits"] || %{})
    contracts = stringify_keys(raw["contracts"] || %{})

    with :ok <- reject_unknown(requires, @requires_keys, ["requires"]),
         :ok <- reject_unknown(operator, @operator_keys, ["operator"]),
         :ok <- reject_unknown(commits, @commits_keys, ["commits"]),
         :ok <- reject_unknown(contracts, @contracts_keys, ["contracts"]),
         {:ok, required_capabilities} <- string_list(requires["capabilities"], []),
         {:ok, contract_modules} <- string_list(contracts["modules"], []),
         {:ok, contract_artifacts} <- parse_artifacts(contracts["artifacts"], repositories),
         {:ok, workspace_root} <- resolve_root(operator["workspace_root"], :data, id),
         {:ok, runtime_root} <- resolve_root(operator["runtime_root"], :state, id) do
      {:ok,
       %__MODULE__{
         path: path,
         id: id,
         repositories: repositories,
         workspace_root: workspace_root,
         runtime_root: runtime_root,
         containment: operator["containment"] || "systemd_user",
         prompt_runner_requirement: requires["prompt_runner"],
         required_capabilities: required_capabilities,
         commit_mode: commits["mode"] || "session",
         push_policy: commits["push"] || "explicit",
         failure_policy: raw["failure_policy"] || "fail_fast",
         contract_artifacts: contract_artifacts,
         contract_modules: contract_modules
       }}
    end
  end

  defp parse_repositories(repositories, manifest_dir) when is_map(repositories) do
    repositories
    |> stringify_keys()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {name, attrs}, {:ok, acc} ->
      attrs = stringify_keys(attrs)

      with :ok <- validate_id(name),
           :ok <- reject_unknown(attrs, @repo_keys, ["repositories", name]),
           {:ok, remote} <- required_string(attrs, "remote", ["repositories", name]),
           {:ok, ref} <- optional_string(attrs, "ref", "main", ["repositories", name]),
           {:ok, source} <- optional_path(attrs["source"], manifest_dir) do
        repo = %{name: name, remote: remote, ref: ref, source: source}
        {:cont, {:ok, Map.put(acc, name, repo)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, repos} when map_size(repos) > 0 -> {:ok, repos}
      {:ok, _repos} -> {:error, :workspace_repositories_empty}
      error -> error
    end
  end

  defp parse_repositories(_repositories, _manifest_dir),
    do: {:error, :workspace_repositories_invalid}

  defp require_schema(%{"schema" => @schema}), do: :ok

  defp require_schema(%{"schema" => schema}),
    do: {:error, {:unsupported_workspace_schema, schema}}

  defp require_schema(_raw), do: {:error, {:missing_workspace_key, "schema"}}

  defp reject_unknown(map, allowed, path) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_workspace_keys, path, Enum.sort(unknown)}}
    end
  end

  defp required_string(map, key, path) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing_workspace_key, Enum.join(path ++ [key], ".")}}
      value -> {:error, {:invalid_workspace_value, path ++ [key], value}}
    end
  end

  defp optional_string(map, key, default, path) do
    case map[key] do
      nil -> {:ok, default}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_workspace_value, path ++ [key], value}}
    end
  end

  defp string_list(nil, default), do: {:ok, default}

  defp string_list(values, _default) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, {:invalid_string_list, values}}
  end

  defp string_list(value, _default), do: {:error, {:invalid_string_list, value}}

  defp parse_artifacts(nil, _repositories), do: {:ok, []}

  defp parse_artifacts(artifacts, repositories) when is_list(artifacts) do
    artifacts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      artifact = stringify_keys(raw)
      path = ["contracts", "artifacts", Integer.to_string(index)]

      with :ok <- reject_unknown(artifact, @artifact_keys, path),
           {:ok, id} <- required_string(artifact, "id", path),
           :ok <- validate_id(id),
           {:ok, repo} <- required_string(artifact, "repo", path),
           true <-
             Map.has_key?(repositories, repo) || {:error, {:unknown_artifact_repo, id, repo}},
           {:ok, project} <- required_string(artifact, "project", path),
           type = artifact["type"] || "escript",
           true <- type == "escript" || {:error, {:unsupported_artifact_type, id, type}} do
        {:cont, {:ok, acc ++ [%{id: id, repo: repo, project: project, type: type}]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> unique_artifacts()
  end

  defp parse_artifacts(value, _repositories), do: {:error, {:invalid_contract_artifacts, value}}

  defp unique_artifacts({:ok, parsed}) do
    ids = Enum.map(parsed, & &1.id)

    if length(ids) == length(Enum.uniq(ids)),
      do: {:ok, parsed},
      else: {:error, :duplicate_artifact_ids}
  end

  defp unique_artifacts(error), do: error

  defp optional_path(nil, _base), do: {:ok, nil}
  defp optional_path(path, base) when is_binary(path), do: {:ok, Path.expand(path, base)}
  defp optional_path(value, _base), do: {:error, {:invalid_source_path, value}}

  defp resolve_root(nil, kind, id), do: resolve_root("auto", kind, id)

  defp resolve_root("auto", :data, id) do
    {:ok,
     Path.join([xdg_root("XDG_DATA_HOME", ".local/share"), "prompt_runner", "workspaces", id])}
  end

  defp resolve_root("auto", :state, id) do
    {:ok,
     Path.join([xdg_root("XDG_STATE_HOME", ".local/state"), "prompt_runner", "workspaces", id])}
  end

  defp resolve_root(path, _kind, _id) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, Path.expand(path)},
      else: {:error, {:workspace_root_not_absolute, path}}
  end

  defp resolve_root(value, kind, _id), do: {:error, {:invalid_workspace_root, kind, value}}

  defp xdg_root(variable, fallback) do
    System.get_env(variable) || Path.join(System.user_home!(), fallback)
  end

  defp validate_id(value) when is_binary(value) do
    if value =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/,
      do: :ok,
      else: {:error, {:invalid_workspace_id, value}}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(_other), do: %{}
  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
