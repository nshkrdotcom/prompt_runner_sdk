defmodule PromptRunner.Control.Subscriber do
  @moduledoc """
  Follows a run's event stream and forwards it to a subscribing process.

  Started by `PromptRunner.Control.subscribe/3`; callers do not start this
  directly. It tails `control/events.jsonl` rather than attaching to the
  session, so a subscriber cannot slow, block, or crash the run it is watching,
  and works identically whether it shares a VM with the runner or not.

  Messages sent to the subscriber:

  - `{:prompt_runner_event, ref, event}` — one canonical event, exactly as it
    was written, so a map with string keys
  - `{:prompt_runner_control, ref, {:run_finished, status}}` — the run reached a
    terminal status and the stream has been drained

  The subscriber process monitors its target and stops when the target dies, so
  a dashboard crashing does not leave a poller behind.
  """

  use GenServer

  alias PromptRunner.Control.Store

  @default_interval_ms 200

  @type opts :: [
          packet_dir: String.t(),
          run_id: String.t(),
          target: pid(),
          ref: reference(),
          from: :start | :current,
          interval_ms: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    packet_dir = Keyword.fetch!(opts, :packet_dir)
    target = Keyword.fetch!(opts, :target)
    path = Store.events_path(packet_dir)

    state = %{
      packet_dir: packet_dir,
      run_id: Keyword.fetch!(opts, :run_id),
      target: target,
      ref: Keyword.fetch!(opts, :ref),
      monitor: Process.monitor(target),
      path: path,
      offset: starting_offset(path, Keyword.get(opts, :from, :start)),
      buffer: "",
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      finished?: false
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    state = state |> drain() |> maybe_finish()

    if state.finished? do
      {:stop, :normal, state}
    else
      {:noreply, schedule(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    Process.send_after(self(), :poll, state.interval_ms)
    state
  end

  # Reads whatever has been appended since the last poll. A partial trailing
  # line is kept in the buffer rather than decoded: the writer appends whole
  # lines, but a reader can still catch one mid-write.
  defp drain(state) do
    case File.open(state.path, [:read, :binary]) do
      {:ok, io} ->
        try do
          :file.position(io, state.offset)
          read_available(io, state)
        after
          File.close(io)
        end

      {:error, _reason} ->
        state
    end
  end

  defp read_available(io, state) do
    case IO.binread(io, :eof) do
      data when is_binary(data) and data != "" ->
        {lines, rest} = split_lines(state.buffer <> data)
        Enum.each(lines, &forward(state, &1))
        %{state | offset: state.offset + byte_size(data), buffer: rest}

      _other ->
        state
    end
  end

  defp split_lines(content) do
    parts = String.split(content, "\n")
    {complete, [trailing]} = Enum.split(parts, length(parts) - 1)
    {complete, trailing}
  end

  defp forward(state, line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        send(state.target, {:prompt_runner_event, state.ref, event})

      _other ->
        :ok
    end
  end

  # The run is over only once the stream has been drained past the point at
  # which the status turned terminal; checking the snapshot first would drop
  # the last events of a run that finished between polls.
  defp maybe_finish(state) do
    case Store.read_snapshot(state.packet_dir) do
      {:ok, %{run_id: run_id, status: status}}
      when status in [:completed, :failed] ->
        if run_id == state.run_id do
          send(state.target, {:prompt_runner_control, state.ref, {:run_finished, status}})
          %{state | finished?: true}
        else
          state
        end

      _other ->
        state
    end
  end

  defp starting_offset(path, :current) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _other -> 0
    end
  end

  defp starting_offset(_path, _from), do: 0
end
