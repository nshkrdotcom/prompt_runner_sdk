defmodule PromptRunner.Control.Store do
  @moduledoc """
  The file transport for one control-plane state root.

  ```
  control/
    requests/     one file per command, retained until an outcome is durable
    outcomes/     immutable request outcome receipts
    log.jsonl     append-only: every command, who, when, outcome
    snapshot.json atomically replaced on each event batch
    events.jsonl  append-only canonical event stream for subscribers
    events/       append-only streams archived by run id
  ```

  A directory rather than a socket, for the first transport: no daemon, no
  port, no supervision tree to get wrong; it works under `tee`, `nohup`, tmux,
  and with no terminal at all; it survives the runner dying, because the
  requests are just sitting there; and it is trivially inspectable when
  something goes wrong.

  It also forces the API to be serialisable and asynchronous from day one,
  which is the discipline that keeps the CLI from quietly becoming privileged.
  """

  alias PromptRunner.Control.{Entry, Snapshot}
  alias PromptRunner.Paths

  @dir ".prompt_runner"
  @control "control"

  @typedoc "A legacy packet root or an explicit runtime state root."
  @type root :: String.t() | {:state_root, String.t()}

  @doc "Tags an operator-owned runtime directory for use as the control state root."
  @spec state_root(String.t()) :: {:state_root, String.t()}
  def state_root(path) when is_binary(path), do: {:state_root, Paths.resolve(path)}

  @spec control_dir(root()) :: String.t()
  def control_dir({:state_root, state_root}) when is_binary(state_root) do
    state_root |> Paths.resolve() |> Path.join(@control)
  end

  def control_dir(packet_dir) when is_binary(packet_dir) do
    packet_dir |> Paths.resolve() |> Path.join(@dir) |> Path.join(@control)
  end

  @spec requests_dir(root()) :: String.t()
  def requests_dir(root), do: Path.join(control_dir(root), "requests")

  @spec outcomes_dir(root()) :: String.t()
  def outcomes_dir(root), do: Path.join(control_dir(root), "outcomes")

  @spec snapshot_path(root()) :: String.t()
  def snapshot_path(root), do: Path.join(control_dir(root), "snapshot.json")

  @spec log_path(root()) :: String.t()
  def log_path(root), do: Path.join(control_dir(root), "log.jsonl")

  @spec events_path(root()) :: String.t()
  def events_path(root), do: Path.join(control_dir(root), "events.jsonl")

  @spec init(root()) :: :ok | {:error, term()}
  def init(root) do
    with :ok <- File.mkdir_p(requests_dir(root)) do
      File.mkdir_p(outcomes_dir(root))
    end
  end

  @doc """
  Rewrites `snapshot.json`.

  Written to a temporary file and renamed, because a reader polling this file
  must never observe a half-written one. A rename within a directory is atomic
  on every filesystem this runs on.
  """
  @spec write_snapshot(root(), Snapshot.t()) :: :ok | {:error, term()}
  def write_snapshot(root, %Snapshot{} = snapshot) do
    root
    |> snapshot_path()
    |> atomic_write(Jason.encode!(Snapshot.to_map(snapshot), pretty: true))
  end

  @spec read_snapshot(root()) :: {:ok, Snapshot.t()} | {:error, term()}
  def read_snapshot(root) do
    case File.read(snapshot_path(root)) do
      {:ok, content} -> decode_snapshot(content)
      {:error, :enoent} -> {:error, :no_run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_snapshot(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        {:ok, Snapshot.from_map(map)}

      {:ok, other} ->
        {:error, {:not_an_object, other}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  @spec append_log(root(), Entry.t()) :: :ok | {:error, term()}
  def append_log(root, %Entry{} = entry) do
    append_jsonl(log_path(root), Entry.to_map(entry))
  end

  @spec read_log(root()) :: {:ok, [Entry.t()]}
  def read_log(root) do
    {:ok, root |> log_path() |> read_jsonl() |> Enum.map(&Entry.from_map/1)}
  end

  @spec append_event(root(), map()) :: :ok | {:error, term()}
  def append_event(root, event) when is_map(event) do
    append_jsonl(events_path(root), event)
  end

  @doc """
  Prepares the subscriber event stream for `run_id` without truncating bytes.

  Reopening the same run leaves the current stream in place and continues
  appending. Opening a different run atomically archives the current stream by
  its previous run id. A subscriber reading the canonical path therefore sees
  only the current run, while prior streams remain available for audit.
  """
  @spec prepare_event_stream(root(), String.t()) :: :ok | {:error, term()}
  def prepare_event_stream(root, run_id) when is_binary(run_id) do
    previous_run_id =
      case read_snapshot(root) do
        {:ok, %Snapshot{run_id: previous}} -> previous
        _other -> nil
      end

    if previous_run_id in [nil, run_id],
      do: :ok,
      else: archive_event_stream(root, previous_run_id)
  end

  @doc """
  Legacy compatibility hook.

  Event streams are append-only now, so resetting is intentionally a no-op.
  New code should call `prepare_event_stream/2`.
  """
  @spec reset_events(root()) :: :ok | {:error, term()}
  def reset_events(root), do: init(root)

  @spec archived_events_path(root(), String.t()) :: String.t()
  def archived_events_path(root, run_id) when is_binary(run_id) do
    Path.join([control_dir(root), "events", safe_filename(run_id) <> ".jsonl"])
  end

  @doc """
  Writes one request file.

  The name carries a sortable timestamp and a unique suffix, so requests are
  consumed in arrival order and two writers racing cannot collide on a name.
  """
  @spec write_request(root(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_request(root, request) when is_map(request) do
    dir = requests_dir(root)
    name = request_name()
    path = Path.join(dir, name)

    with :ok <- File.mkdir_p(dir),
         :ok <- atomic_write(path, Jason.encode!(request)) do
      {:ok, path}
    end
  end

  @doc """
  Reads every pending request without deleting it.

  Requests with an existing durable outcome receipt are acknowledged and
  skipped. This closes the crash window between writing the receipt and
  removing the inbox file without applying the request twice.
  """
  @spec pending_requests(root()) :: [{String.t(), {:ok, map()} | {:error, term()}}]
  def pending_requests(root) do
    dir = requests_dir(root)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(&pending_request(root, dir, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Persists an immutable request outcome, then removes the pending request.

  The ordering is the durability guarantee: a crash may leave both files, but
  can never remove the request before its outcome exists.
  """
  @spec complete_request(root(), String.t(), map()) :: :ok | {:error, term()}
  def complete_request(root, name, outcome) when is_binary(name) and is_map(outcome) do
    receipt =
      outcome
      |> Map.put_new("request", name)
      |> Map.put_new("recorded_at", DateTime.utc_now() |> DateTime.to_iso8601())

    with :ok <- write_outcome_once(root, name, receipt) do
      remove_request(root, name)
    end
  end

  @spec request_outcome_path(root(), String.t()) :: String.t()
  def request_outcome_path(root, name) when is_binary(name) do
    Path.join(outcomes_dir(root), safe_filename(name))
  end

  @doc """
  Reads and deletes every pending request, in arrival order.

  This preserves the legacy Store API. The control plane no longer uses it,
  because it cannot provide durable request outcomes. New consumers should use
  `pending_requests/1` and `complete_request/3`.
  """
  @spec take_requests(root()) :: [{String.t(), {:ok, map()} | {:error, term()}}]
  def take_requests(root) do
    requests = pending_requests(root)
    Enum.each(requests, fn {name, _result} -> remove_request(root, name) end)
    requests
  end

  defp pending_request(root, dir, name) do
    path = Path.join(dir, name)

    if File.exists?(request_outcome_path(root, name)) do
      File.rm(path)
      []
    else
      [{name, read_request(path)}]
    end
  end

  defp read_request(path) do
    with {:ok, content} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(content) do
      {:ok, map}
    else
      {:ok, other} ->
        {:error, {:not_an_object, other}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Monotonic within a process and unique across processes: the timestamp gives
  # arrival order between writers, the counter breaks ties within one.
  defp request_name do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S-%f")
    "#{stamp}-#{System.unique_integer([:positive, :monotonic])}.json"
  end

  @doc false
  @spec read_jsonl(String.t()) :: [map()]
  def read_jsonl(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.flat_map(&decode_line/1)
      {:error, _reason} -> []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _other -> []
    end
  end

  defp archive_event_stream(root, previous_run_id) do
    source = events_path(root)

    case File.stat(source) do
      {:ok, _stat} ->
        destination = unique_archive_path(root, previous_run_id)

        with :ok <- File.mkdir_p(Path.dirname(destination)) do
          File.rename(source, destination)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique_archive_path(root, run_id) do
    base = archived_events_path(root, run_id)

    if File.exists?(base) do
      ext = System.unique_integer([:positive, :monotonic])
      Path.rootname(base) <> "-#{ext}.jsonl"
    else
      base
    end
  end

  defp write_outcome_once(root, name, receipt) do
    path = request_outcome_path(root, name)

    if File.exists?(path) do
      :ok
    else
      atomic_write(path, Jason.encode!(receipt, pretty: true))
    end
  end

  defp remove_request(root, name) do
    case File.rm(Path.join(requests_dir(root), name)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_jsonl(path, value) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :binary]) do
      try do
        with :ok <- IO.binwrite(io, Jason.encode!(value) <> "\n") do
          :file.sync(io)
        end
      after
        File.close(io)
      end
    end
  end

  defp atomic_write(path, content) when is_binary(content) do
    tmp =
      path <>
        ".tmp-#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:nanosecond)}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]) do
      io
      |> write_and_sync(content)
      |> finish_atomic_write(tmp, path)
    end
  end

  defp write_and_sync(io, content) do
    result =
      with :ok <- IO.binwrite(io, content) do
        :file.sync(io)
      end

    result
  after
    File.close(io)
  end

  defp finish_atomic_write(:ok, tmp, path), do: rename_atomic_file(tmp, path)

  defp finish_atomic_write({:error, _reason} = error, tmp, _path) do
    File.rm(tmp)
    error
  end

  defp rename_atomic_file(tmp, path) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, _reason} = error -> remove_failed_temp(tmp, error)
    end
  end

  defp remove_failed_temp(tmp, error) do
    File.rm(tmp)
    error
  end

  defp safe_filename(value) do
    String.replace(value, ~r/[^A-Za-z0-9._-]/u, "_")
  end
end
