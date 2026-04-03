defmodule PromptRunner.Rendering do
  @moduledoc """
  Renders prompt-runner canonical event streams through a pluggable renderer and sink pipeline.
  """

  alias PromptRunner.Rendering.{Renderer, Sink}

  @type renderer_spec :: {module(), Renderer.opts()}
  @type sink_spec :: {module(), Sink.opts()}

  @type opts :: [
          renderer: renderer_spec(),
          sinks: [sink_spec()]
        ]

  @spec stream(Enumerable.t(), opts()) :: :ok | {:error, term()}
  def stream(event_stream, opts) do
    {renderer_mod, renderer_opts} = Keyword.fetch!(opts, :renderer)
    sink_specs = Keyword.get(opts, :sinks, [])

    with {:ok, renderer_state} <- renderer_mod.init(renderer_opts),
         {:ok, sink_states} <- init_sinks(sink_specs) do
      {final_renderer_state, final_sink_states} =
        Enum.reduce(event_stream, {renderer_state, sink_states}, fn event, {r_state, s_states} ->
          {:ok, iodata, new_r_state} = renderer_mod.render_event(event, r_state)
          new_s_states = write_to_sinks(s_states, event, iodata)
          {new_r_state, new_s_states}
        end)

      {:ok, final_iodata, _final_renderer_state} = renderer_mod.finish(final_renderer_state)

      if IO.iodata_length(final_iodata) > 0 do
        write_rendered_to_sinks(final_sink_states, final_iodata)
      else
        final_sink_states
      end
      |> flush_sinks()
      |> close_sinks()

      :ok
    end
  end

  defp init_sinks(sink_specs) do
    results =
      Enum.map(sink_specs, fn {mod, opts} ->
        case mod.init(opts) do
          {:ok, state} -> {:ok, {mod, state}}
          {:error, reason} -> {:error, reason}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, s} -> s end)}
    end
  end

  defp write_to_sinks(sink_states, event, iodata) do
    Enum.map(sink_states, fn {mod, state} ->
      {:ok, new_state} = mod.write_event(event, iodata, state)
      {mod, new_state}
    end)
  end

  defp write_rendered_to_sinks(sink_states, iodata) do
    Enum.map(sink_states, fn {mod, state} ->
      {:ok, new_state} = mod.write(iodata, state)
      {mod, new_state}
    end)
  end

  defp flush_sinks(sink_states) do
    Enum.each(sink_states, fn {mod, state} ->
      mod.flush(state)
    end)

    sink_states
  end

  defp close_sinks(sink_states) do
    Enum.each(sink_states, fn {mod, state} ->
      mod.close(state)
    end)
  end
end
