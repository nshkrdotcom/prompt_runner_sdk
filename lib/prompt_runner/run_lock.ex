defmodule PromptRunner.RunLock do
  @moduledoc false

  @type identity :: %{pid: pos_integer(), start_time: String.t() | nil}

  @spec with_lock(String.t(), (-> result)) :: result | {:error, term()} when result: term()
  def with_lock(path, fun) when is_binary(path) and is_function(fun, 0) do
    File.mkdir_p!(Path.dirname(path))
    identity = current_identity()
    token = encode(identity)

    case acquire(path, token, 0) do
      :ok ->
        try do
          fun.()
        after
          release(path, token)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec status(String.t()) :: {:up | :down, pos_integer() | nil}
  def status(path) when is_binary(path) do
    case read_identity(path) do
      {:ok, identity} -> {if(alive?(identity), do: :up, else: :down), identity.pid}
      {:error, _reason} -> {:down, nil}
    end
  end

  @spec current_identity() :: identity()
  def current_identity do
    pid = System.pid() |> String.to_integer()
    %{pid: pid, start_time: process_start_time(pid)}
  end

  defp acquire(path, token, stale_retries) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, token)
          :file.sync(io)
          :ok
        after
          File.close(io)
        end

      {:error, :eexist} ->
        resolve_existing_lock(path, token, stale_retries)

      {:error, reason} ->
        {:error, {:run_lock_unavailable, path, reason}}
    end
  end

  defp resolve_existing_lock(path, token, stale_retries) do
    case read_identity(path) do
      {:ok, identity} ->
        if alive?(identity) do
          {:error, {:run_already_active, path, identity.pid}}
        else
          replace_stale_lock(path, token, stale_retries)
        end

      # An exclusive creator can be between open and write. Refuse the first
      # observation instead of unlinking a lock another runner just acquired.
      {:error, :empty} when stale_retries == 0 ->
        Process.sleep(10)
        resolve_existing_lock(path, token, 1)

      {:error, _reason} ->
        replace_stale_lock(path, token, stale_retries)
    end
  end

  defp replace_stale_lock(path, token, stale_retries) when stale_retries < 2 do
    case File.rm(path) do
      :ok -> acquire(path, token, stale_retries + 1)
      {:error, :enoent} -> acquire(path, token, stale_retries + 1)
      {:error, reason} -> {:error, {:stale_run_lock_unremovable, path, reason}}
    end
  end

  defp replace_stale_lock(path, _token, _stale_retries),
    do: {:error, {:run_lock_contended, path}}

  defp release(path, token) do
    # Never remove a successor's lock if the path was replaced while the run
    # was active or while unwinding after a crash.
    if File.read(path) == {:ok, token}, do: File.rm(path)
    :ok
  end

  defp read_identity(path) do
    with {:ok, contents} <- File.read(path) do
      decode_identity(contents)
    end
  end

  defp decode_identity(contents) do
    case String.split(contents) do
      [] ->
        {:error, :empty}

      [pid_text] ->
        parse_identity(pid_text, nil)

      [pid_text, start_time] ->
        if start_time =~ ~r/^\d+$/,
          do: parse_identity(pid_text, start_time),
          else: {:error, :invalid}

      _other ->
        {:error, :invalid}
    end
  end

  defp parse_identity(pid_text, start_time) do
    case Integer.parse(pid_text) do
      {pid, ""} when pid > 0 -> {:ok, %{pid: pid, start_time: start_time}}
      _other -> {:error, :invalid}
    end
  end

  defp encode(%{pid: pid, start_time: nil}), do: "#{pid}\n"
  defp encode(%{pid: pid, start_time: start_time}), do: "#{pid} #{start_time}\n"

  defp alive?(%{pid: pid, start_time: expected_start}) do
    if File.dir?("/proc") do
      File.dir?("/proc/#{pid}") and start_time_matches?(pid, expected_start)
    else
      match?(
        {_output, 0},
        System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
      )
    end
  end

  # Old pid-only files remain readable. They cannot protect against PID reuse,
  # but treating a live legacy pid conservatively avoids overlapping runs.
  defp start_time_matches?(_pid, nil), do: true
  defp start_time_matches?(pid, expected), do: process_start_time(pid) == expected

  # `/proc/<pid>/stat` field 22 is the process start time. Splitting after the
  # final `) ` keeps spaces and parentheses inside the command name harmless.
  defp process_start_time(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [suffix, _command_and_pid] <-
           stat |> String.split(") ") |> Enum.reverse() |> Enum.take(2),
         start_time when is_binary(start_time) <- suffix |> String.split() |> Enum.at(19) do
      start_time
    else
      _other -> nil
    end
  end
end
