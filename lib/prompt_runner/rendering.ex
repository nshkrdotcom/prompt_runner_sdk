defmodule PromptRunner.Rendering do
  @moduledoc """
  Renders prompt-runner canonical event streams through a pluggable renderer and sink pipeline.
  """

  alias PromptRunner.Rendering.{Renderer, Sink}

  @type renderer_spec :: {module(), Renderer.opts()}
  @type sink_spec :: {module(), Sink.opts()}

  @typedoc """
  What a boundary hook may ask the pipeline to do after an event.

  `{:set_view, view}` reaches the live renderer through
  `c:PromptRunner.Rendering.Renderer.set_view/2`; `{:renderer, spec}` replaces
  the renderer outright, which is what a `log_mode` change means.
  """
  @type command :: {:set_view, map()} | {:renderer, renderer_spec()}

  @type opts :: [
          renderer: renderer_spec(),
          sinks: [sink_spec()],
          boundary: (map() -> [command()])
        ]

  @spec stream(Enumerable.t(), opts()) :: :ok | {:error, term()}
  def stream(event_stream, opts) do
    {renderer_mod, renderer_opts} = Keyword.fetch!(opts, :renderer)
    sink_specs = Keyword.get(opts, :sinks, [])
    boundary = Keyword.get(opts, :boundary)

    with {:ok, renderer_state} <- renderer_mod.init(renderer_opts),
         {:ok, sink_states} <- init_sinks(sink_specs) do
      initial = {{renderer_mod, renderer_state}, sink_states}

      {{final_renderer_mod, final_renderer_state}, final_sink_states} =
        Enum.reduce(event_stream, initial, fn event, {renderer, s_states} ->
          {mod, r_state} = renderer
          {:ok, iodata, new_r_state} = mod.render_event(event, r_state)
          new_s_states = write_to_sinks(s_states, event, iodata)
          {apply_boundary(boundary, event, {mod, new_r_state}), new_s_states}
        end)

      renderer_mod = final_renderer_mod

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

  # Requests are consumed between events, never inside one: a view that changed
  # halfway through rendering an event produces output belonging to neither
  # setting.
  defp apply_boundary(nil, _event, renderer), do: renderer

  defp apply_boundary(boundary, event, renderer) do
    boundary
    |> apply_boundary_fun(event)
    |> Enum.reduce(renderer, &apply_command/2)
  end

  defp apply_boundary_fun(boundary, event) do
    case boundary.(event) do
      commands when is_list(commands) -> commands
      _other -> []
    end
  end

  defp apply_command({:set_view, view}, {mod, state}) when is_map(view) do
    if function_exported?(mod, :set_view, 2) do
      {:ok, new_state} = mod.set_view(view, state)
      {mod, new_state}
    else
      {mod, state}
    end
  end

  # A `log_mode` change is a different renderer, not a different setting on the
  # one already running. Whatever the outgoing renderer had accumulated —
  # counters, open lines — goes with it; the alternative is a renderer holding
  # another renderer's state.
  defp apply_command({:renderer, {new_mod, new_opts}}, {mod, state}) do
    case new_mod.init(new_opts) do
      {:ok, new_state} -> {new_mod, new_state}
      {:error, _reason} -> {mod, state}
    end
  end

  defp apply_command(_command, renderer), do: renderer

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
