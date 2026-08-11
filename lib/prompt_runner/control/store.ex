defmodule PromptRunner.Control.Store do
  @moduledoc """
  The file transport under `.prompt_runner/control/`.

  ```
  control/
    requests/     one file per command, consumed and deleted
    log.jsonl     append-only: every command, who, when, outcome
    snapshot.json rewritten on each event batch
    events.jsonl  append-only canonical event stream for subscribers
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

  @spec control_dir(String.t()) :: String.t()
  def control_dir(packet_dir) when is_binary(packet_dir) do
    packet_dir |> Paths.resolve() |> Path.join(@dir) |> Path.join(@control)
  end

  @spec requests_dir(String.t()) :: String.t()
  def requests_dir(packet_dir), do: Path.join(control_dir(packet_dir), "requests")

  @spec snapshot_path(String.t()) :: String.t()
  def snapshot_path(packet_dir), do: Path.join(control_dir(packet_dir), "snapshot.json")

  @spec log_path(String.t()) :: String.t()
  def log_path(packet_dir), do: Path.join(control_dir(packet_dir), "log.jsonl")

  @spec events_path(String.t()) :: String.t()
  def events_path(packet_dir), do: Path.join(control_dir(packet_dir), "events.jsonl")

  @spec init(String.t()) :: :ok
  def init(packet_dir) do
    File.mkdir_p!(requests_dir(packet_dir))
    :ok
  end

  @doc """
  Rewrites `snapshot.json`.

  Written to a temporary file and renamed, because a reader polling this file
  must never observe a half-written one. A rename within a directory is atomic
  on every filesystem this runs on.
  """
  @spec write_snapshot(String.t(), Snapshot.t()) :: :ok | {:error, term()}
  def write_snapshot(packet_dir, %Snapshot{} = snapshot) do
    path = snapshot_path(packet_dir)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(Snapshot.to_map(snapshot), pretty: true)) do
      File.rename(tmp, path)
    end
  end

  @spec read_snapshot(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def read_snapshot(packet_dir) do
    case File.read(snapshot_path(packet_dir)) do
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

  @spec append_log(String.t(), Entry.t()) :: :ok | {:error, term()}
  def append_log(packet_dir, %Entry{} = entry) do
    path = log_path(packet_dir)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(Entry.to_map(entry)) <> "\n", [:append])
    end
  end

  @spec read_log(String.t()) :: {:ok, [Entry.t()]}
  def read_log(packet_dir) do
    {:ok, packet_dir |> log_path() |> read_jsonl() |> Enum.map(&Entry.from_map/1)}
  end

  @spec append_event(String.t(), map()) :: :ok | {:error, term()}
  def append_event(packet_dir, event) when is_map(event) do
    path = events_path(packet_dir)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(event) <> "\n", [:append])
    end
  end

  @doc """
  Truncates the subscriber event stream.

  Called once when a run starts. The stream is scoped to the run in flight, so
  a subscriber reading from the beginning gets this run rather than a
  concatenation of every run the packet has ever had.
  """
  @spec reset_events(String.t()) :: :ok | {:error, term()}
  def reset_events(packet_dir) do
    path = events_path(packet_dir)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, "")
    end
  end

  @doc """
  Writes one request file.

  The name carries a sortable timestamp and a unique suffix, so requests are
  consumed in arrival order and two writers racing cannot collide on a name.
  """
  @spec write_request(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_request(packet_dir, request) when is_map(request) do
    dir = requests_dir(packet_dir)
    name = request_name()
    path = Path.join(dir, name)
    tmp = Path.join(dir, "." <> name)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode!(request)),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    end
  end

  @doc """
  Reads and deletes every pending request, in arrival order.

  Deleting before returning is deliberate: a request that cannot be parsed, or
  whose handler raises, must not be retried on the next boundary forever. It is
  logged and gone.
  """
  @spec take_requests(String.t()) :: [{String.t(), {:ok, map()} | {:error, term()}}]
  def take_requests(packet_dir) do
    dir = requests_dir(packet_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.map(&take_request(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp take_request(dir, name) do
    path = Path.join(dir, name)
    result = read_request(path)
    File.rm(path)
    {name, result}
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
end
