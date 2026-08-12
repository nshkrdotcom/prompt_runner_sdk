defmodule PromptRunner.Workspace.Reference do
  @moduledoc "Resolves prepared workspaces by manifest path, id, or current directory."

  alias PromptRunner.Paths
  alias PromptRunner.Workspace.Manifest

  @lock_schema "prompt_runner.workspace.lock/v1"
  @reference_schema "prompt_runner.workspace.reference/v1"

  @doc false
  @spec register(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def register(id, manifest_path, lock_path)
      when is_binary(id) and is_binary(manifest_path) and is_binary(lock_path) do
    reference = %{
      schema: @reference_schema,
      workspace: id,
      manifest: Paths.resolve(manifest_path),
      lock: Paths.resolve(lock_path),
      written_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    atomic_write(reference_path(id), Jason.encode!(reference, pretty: true))
  end

  @spec resolve(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(reference \\ nil, opts \\ [])

  def resolve(reference, _opts) when is_binary(reference) do
    cond do
      File.regular?(reference) -> {:ok, Paths.resolve(reference)}
      path_reference?(reference) -> {:ok, Paths.resolve(reference)}
      true -> resolve_id(reference)
    end
  end

  def resolve(nil, opts) do
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Paths.resolve()

    case Enum.filter(prepared(), &related?(&1, cwd)) do
      [%{manifest: manifest}] -> {:ok, manifest}
      [] -> {:error, {:workspace_not_discovered, cwd}}
      matches -> {:error, {:workspace_discovery_ambiguous, cwd, Enum.map(matches, & &1.id)}}
    end
  end

  defp resolve_id(id) do
    if valid_id?(id) do
      case id_lock_path(id) |> read_lock() do
        {:ok, %{id: ^id, manifest: manifest}} -> {:ok, manifest}
        {:ok, %{id: actual}} -> {:error, {:workspace_identity_mismatch, id, actual}}
        {:error, _reason} -> {:error, {:workspace_not_prepared, id}}
      end
    else
      {:error, {:invalid_workspace_id, id}}
    end
  end

  defp prepared do
    (reference_locks() ++ default_locks())
    |> Enum.flat_map(fn path ->
      case read_lock(path) do
        {:ok, record} -> [record]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp reference_locks do
    reference_root()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_reference(path) do
        {:ok, lock_path} -> [lock_path]
        {:error, _reason} -> []
      end
    end)
  end

  defp default_locks do
    workspace_root()
    |> Path.join("*/workspace.lock.json")
    |> Path.wildcard()
  end

  defp read_reference(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"schema" => @reference_schema, "workspace" => id, "lock" => lock_path}}
         when is_binary(id) and is_binary(lock_path) <- Jason.decode(contents),
         true <- Path.basename(path, ".json") == id do
      {:ok, lock_path}
    else
      _other -> {:error, :invalid_workspace_reference}
    end
  end

  defp read_lock(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"schema" => @lock_schema, "workspace" => id, "manifest" => manifest} = lock}
         when is_binary(id) and is_binary(manifest) <- Jason.decode(contents),
         true <- File.regular?(manifest),
         {:ok, parsed} <- Manifest.load(manifest),
         true <- parsed.id == id do
      {:ok,
       %{
         id: id,
         manifest: Paths.resolve(manifest),
         repositories: lock["repositories"] || %{},
         parsed: parsed
       }}
    else
      _other -> {:error, :invalid_workspace_lock}
    end
  end

  defp related?(record, cwd) do
    manifest_dir = Path.dirname(record.manifest)

    paths =
      [manifest_dir] ++
        Enum.flat_map(record.repositories, fn
          {_name, repo} when is_map(repo) -> [repo["path"]]
          _other -> []
        end) ++
        Enum.flat_map(record.parsed.repositories, fn {_name, repo} -> [repo.source] end)

    Enum.any?(paths, fn
      path when is_binary(path) -> ancestor?(path, cwd) or ancestor?(cwd, path)
      _other -> false
    end)
  end

  defp ancestor?(ancestor, path) do
    ancestor = ancestor |> Paths.resolve() |> Path.split()
    path = path |> Paths.resolve() |> Path.split()
    Enum.take(path, length(ancestor)) == ancestor
  end

  defp id_lock_path(id) do
    case read_reference(reference_path(id)) do
      {:ok, lock_path} -> lock_path
      {:error, _reason} -> Path.join([workspace_root(), id, "workspace.lock.json"])
    end
  end

  defp reference_path(id), do: Path.join(reference_root(), id <> ".json")

  defp path_reference?(reference) do
    Path.type(reference) == :absolute or String.contains?(reference, ["/", "\\"]) or
      Path.extname(reference) in [".yml", ".yaml"]
  end

  defp valid_id?(id), do: id =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

  defp data_root do
    root = System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share")
    Path.join(root, "prompt_runner")
  end

  defp workspace_root, do: Path.join(data_root(), "workspaces")
  defp reference_root, do: Path.join(data_root(), "workspace-references")

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
