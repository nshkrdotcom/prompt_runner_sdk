defmodule PromptRunner.Watch do
  @moduledoc """
  Supervision for a long unattended packet run.

  One compact line per interval, of raw facts:

  ```text
  WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27
  ```

  - `runner` — `UP` when `.prompt_runner/run.pid` names a process that still
    exists. The runner writes that file for the duration of a run. Liveness is
    deliberately *not* a process-name match: such a pattern matches any command
    line containing it, including the supervisor's own shell, and an earlier
    implementation of exactly this check reported a healthy run forever.
  - `prompt` — the id in the newest `prompt-*.log` under the packet's log
    directory, or `none`.
  - `quiet` — minutes since the newest file mtime across the packet's log
    directory and every configured repository, with `.git` pruned. Mtime, not
    JSON: the event schema differs between `events_mode: compact`
    (`{"t": epoch_ms}`) and `full` (`{"ts": "ISO8601"}`), and an earlier
    implementation parsed one of them and silently reported zero quiet time for
    the other. An mtime cannot be the wrong schema. `?` means no file was
    found to measure.
  - `repos`, `dirty`, `commits` — the number of configured repositories, the
    total `git status --porcelain` line count across them, and the total number
    of commits reachable from each `HEAD`.

  Nothing here decides anything. It reports what is on the machine, in a shape
  a human or an agent can read at a glance, and lets the reader judge. A
  watcher that greps for known failure signatures only catches failures someone
  predicted, and its silence is indistinguishable from health.

  The quiet-time scan walks every configured repository, so on very large
  repositories the default 15-minute interval matters; `--interval` is the
  lever.
  """

  alias PromptRunner.Git
  alias PromptRunner.Packet
  alias PromptRunner.Paths

  @default_interval_seconds 900
  @pruned_entries [".git"]

  @type sample :: %{
          packet: String.t(),
          root: String.t(),
          timestamp: String.t(),
          runner: :up | :down,
          pid: pos_integer() | nil,
          prompt: String.t() | nil,
          quiet_minutes: non_neg_integer() | nil,
          repos: non_neg_integer(),
          dirty: non_neg_integer(),
          commits: non_neg_integer()
        }

  @doc """
  Emits one sample per interval until the process is stopped.

  Options:

  - `:interval` — seconds between samples (default #{@default_interval_seconds}).
  - `:once` — emit a single sample and return.
  - `:json` — emit each sample as one JSON object instead of the compact line.
  """
  @spec run(String.t(), keyword()) :: :ok | {:error, term()}
  def run(packet_dir, opts \\ []) when is_binary(packet_dir) do
    interval_ms = interval_seconds(opts) * 1000

    loop(packet_dir, interval_ms, opts[:once] == true, opts[:json] == true)
  end

  @doc "Collects one sample of the packet's supervision facts."
  @spec sample(String.t(), keyword()) :: {:ok, sample()} | {:error, term()}
  def sample(packet_dir, _opts \\ []) when is_binary(packet_dir) do
    with {:ok, packet} <- Packet.load(packet_dir) do
      {:ok, build_sample(packet)}
    end
  end

  @doc "Renders a sample as the compact one-line form."
  @spec format_line(map()) :: String.t()
  def format_line(sample) do
    "WATCH #{sample.timestamp} runner=#{runner_label(sample.runner)} " <>
      "prompt=#{sample.prompt || "none"} quiet=#{quiet_label(sample.quiet_minutes)}min " <>
      "repos=#{sample.repos} dirty=#{sample.dirty} commits=#{sample.commits}"
  end

  @doc "Renders a sample as one JSON object."
  @spec format_json(map()) :: String.t()
  def format_json(sample), do: Jason.encode!(sample)

  @doc "Returns the interval in seconds resolved from `opts`."
  @spec interval_seconds(keyword()) :: pos_integer()
  def interval_seconds(opts) do
    case opts[:interval] do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> @default_interval_seconds
    end
  end

  defp loop(packet_dir, interval_ms, once?, json?) do
    case sample(packet_dir) do
      {:ok, sample} -> emit_and_continue(sample, packet_dir, interval_ms, once?, json?)
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_and_continue(sample, packet_dir, interval_ms, once?, json?) do
    IO.puts(render(sample, json?))

    if once? do
      :ok
    else
      Process.sleep(interval_ms)
      loop(packet_dir, interval_ms, once?, json?)
    end
  end

  defp render(sample, true), do: format_json(sample)
  defp render(sample, false), do: format_line(sample)

  defp build_sample(packet) do
    state_dir = Paths.state_dir(packet.root)
    log_dir = Paths.log_dir(state_dir)
    repo_paths = Enum.map(packet.repos, & &1.path)
    {runner, pid} = runner_status(Paths.pid_file(state_dir))

    %{
      packet: packet.name,
      root: packet.root,
      timestamp: DateTime.utc_now() |> Calendar.strftime("%H:%MZ"),
      runner: runner,
      pid: pid,
      prompt: latest_prompt(log_dir),
      quiet_minutes: quiet_minutes([log_dir | repo_paths]),
      repos: length(repo_paths),
      dirty: total_dirty(repo_paths),
      commits: total_commits(repo_paths)
    }
  end

  defp runner_label(:up), do: "UP"
  defp runner_label(_status), do: "DOWN"

  defp quiet_label(nil), do: "?"
  defp quiet_label(minutes), do: Integer.to_string(minutes)

  # -- liveness

  defp runner_status(pid_path) do
    case read_pid(pid_path) do
      nil -> {:down, nil}
      pid -> {alive_status(pid), pid}
    end
  end

  defp read_pid(pid_path) do
    with {:ok, contents} <- File.read(pid_path),
         {pid, _rest} <- Integer.parse(String.trim(contents)),
         true <- pid > 0 do
      pid
    else
      _other -> nil
    end
  end

  defp alive_status(pid), do: if(alive?(pid), do: :up, else: :down)

  defp alive?(pid) do
    if File.dir?("/proc") do
      File.dir?("/proc/#{pid}")
    else
      match?(
        {_output, 0},
        System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
      )
    end
  end

  # -- current prompt

  defp latest_prompt(log_dir) do
    log_dir
    |> Path.join("prompt-*.log")
    |> Path.wildcard()
    |> Enum.map(&{mtime(&1) || 0, &1})
    |> newest_path()
    |> prompt_id()
  end

  defp newest_path([]), do: nil
  defp newest_path(entries), do: entries |> Enum.max() |> elem(1)

  defp prompt_id(nil), do: nil

  defp prompt_id(path) do
    case Regex.run(~r/prompt-(\d+)-/, Path.basename(path), capture: :all_but_first) do
      [id] -> id
      _other -> nil
    end
  end

  # -- quiet time

  defp quiet_minutes(paths) do
    case paths |> Enum.flat_map(&mtimes/1) |> newest_mtime() do
      nil -> nil
      newest -> max(div(System.os_time(:second) - newest, 60), 0)
    end
  end

  defp newest_mtime([]), do: nil
  defp newest_mtime(mtimes), do: Enum.max(mtimes)

  defp mtimes(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> directory_mtimes(path)
      {:ok, %File.Stat{mtime: mtime}} -> [mtime]
      {:error, _reason} -> []
    end
  end

  defp directory_mtimes(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @pruned_entries))
        |> Enum.flat_map(&mtimes(Path.join(path, &1)))

      {:error, _reason} ->
        []
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _reason} -> nil
    end
  end

  # -- repository facts

  defp total_dirty(repo_paths) do
    repo_paths
    |> Enum.map(&repo_dirty/1)
    |> Enum.sum()
  end

  defp repo_dirty(path) do
    case Git.status_lines(path) do
      {:ok, lines} -> length(lines)
      {:error, _reason} -> 0
    end
  end

  defp total_commits(repo_paths) do
    repo_paths
    |> Enum.map(&(Git.commit_count(&1) || 0))
    |> Enum.sum()
  end
end
