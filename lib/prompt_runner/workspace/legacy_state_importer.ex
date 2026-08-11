defmodule PromptRunner.Workspace.LegacyStateImporter do
  @moduledoc """
  Imports trusted terminal completion records into an operator workspace.

  Only the latest `completed` record for a prompt is carried forward. Failed,
  running, and otherwise non-terminal work remains eligible to run. The import
  is refused once the destination has progress or while a workspace run is
  active, and a digest-bearing receipt records exactly what was trusted.
  """

  alias PromptRunner.RunLock
  alias PromptRunner.RuntimeStore.FileStore
  alias PromptRunner.Workspace

  @schema "prompt_runner.state_import/v1"

  @spec import(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(manifest_path, packet_path, opts \\ []) do
    source = source_path(packet_path, opts)

    with {:ok, %{workspace: workspace, runner: runner}} <-
           Workspace.plan(manifest_path, packet_path),
         destination = Path.join([workspace.runtime_root, "packet", "progress.log"]),
         :ok <- ensure_inactive(workspace.runtime_root),
         :ok <- ensure_destination_absent(destination),
         {:ok, source_bytes} <- read_source(source),
         {:ok, statuses} <- FileStore.statuses_checked(%{progress_file: source}),
         :ok <- validate_prompt_ids(statuses, runner.prompts),
         {:ok, completed} <- completed_records(statuses, runner.prompts) do
      persist_import(workspace, runner, source, source_bytes, destination, completed)
    end
  end

  defp source_path(packet_path, opts) do
    opts
    |> Keyword.get(
      :source,
      Path.join([packet_root(packet_path), ".prompt_runner", "progress.log"])
    )
    |> Path.expand()
  end

  defp packet_root(path) do
    path = Path.expand(path)
    if File.dir?(path), do: path, else: Path.dirname(path)
  end

  defp ensure_inactive(runtime_root) do
    pid_path = Path.join([runtime_root, "packet", "run.pid"])

    case RunLock.status(pid_path) do
      {:down, _pid} -> :ok
      {:up, pid} -> {:error, {:workspace_run_active, pid}}
    end
  end

  defp ensure_destination_absent(destination) do
    if File.exists?(destination),
      do: {:error, {:workspace_progress_already_exists, destination}},
      else: :ok
  end

  defp read_source(source) do
    case File.read(source) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:legacy_progress_unreadable, source, reason}}
    end
  end

  defp validate_prompt_ids(statuses, prompts) do
    known = MapSet.new(prompts, & &1.num)
    unknown = statuses |> Map.keys() |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()

    if unknown == [],
      do: :ok,
      else: {:error, {:legacy_progress_unknown_prompts, unknown}}
  end

  defp completed_records(statuses, prompts) do
    completed =
      prompts
      |> Enum.map(& &1.num)
      |> Enum.filter(&(get_in(statuses, [&1, :status]) == "completed"))
      |> Enum.map(fn id -> Map.put(Map.fetch!(statuses, id), :id, id) end)

    if completed == [], do: {:error, :legacy_progress_has_no_completions}, else: {:ok, completed}
  end

  defp persist_import(workspace, runner, source, source_bytes, destination, completed) do
    imported_at = DateTime.utc_now() |> DateTime.to_iso8601()
    digest = :crypto.hash(:sha256, source_bytes) |> Base.encode16(case: :lower)
    receipt_path = receipt_path(workspace.runtime_root, imported_at, digest)
    receipt = receipt(workspace, runner, source, digest, imported_at, destination, completed)
    progress = Enum.map_join(completed, "", &progress_line/1)

    with :ok <- atomic_write(receipt_path, Jason.encode!(receipt, pretty: true)),
         :ok <- write_progress(destination, progress, receipt_path) do
      {:ok,
       %{
         schema: @schema,
         workspace: workspace.manifest.id,
         source: source,
         source_sha256: digest,
         progress_file: destination,
         receipt: receipt_path,
         imported_completed: Enum.map(completed, & &1.id)
       }}
    end
  end

  defp receipt_path(runtime_root, imported_at, digest) do
    timestamp = String.replace(imported_at, ~r/[^0-9]/, "")
    filename = "legacy-#{timestamp}-#{binary_part(digest, 0, 12)}.json"
    Path.join([runtime_root, "packet", "imports", filename])
  end

  defp receipt(workspace, runner, source, digest, imported_at, destination, completed) do
    %{
      schema: @schema,
      workspace: workspace.manifest.id,
      packet: Path.basename(runner.source_root),
      packet_root: runner.source_root,
      source: source,
      source_sha256: digest,
      destination: destination,
      imported_at: imported_at,
      policy: "latest_completed_only",
      completed:
        Enum.map(completed, fn record ->
          %{id: record.id, source_timestamp: record.timestamp, source_commit: record.commit}
        end)
    }
  end

  defp progress_line(record) do
    timestamp = record.timestamp || now()
    "#{record.id}:completed:#{timestamp}:no_session\n"
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp write_progress(destination, progress, receipt_path) do
    case atomic_write(destination, progress) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = File.rm(receipt_path)
        error
    end
  end

  defp atomic_write(path, contents) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, contents, [:binary, :sync]),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, reason} -> {:error, {:state_import_write_failed, path, reason}}
      end
    after
      _ = File.rm(temp)
    end
  end
end
