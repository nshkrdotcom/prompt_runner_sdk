defmodule PromptRunner.Rendering.Sinks.TTYSink do
  @moduledoc """
  A sink that writes rendered output to a terminal device.
  """

  @behaviour PromptRunner.Rendering.Sink

  @impl true
  def init(opts) do
    device = Keyword.get(opts, :device, :stdio)
    {:ok, %{device: device}}
  end

  @impl true
  def write(iodata, state) do
    IO.write(state.device, iodata)
    {:ok, state}
  end

  @impl true
  def write_event(_event, iodata, state) do
    IO.write(state.device, iodata)
    {:ok, state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok
end
