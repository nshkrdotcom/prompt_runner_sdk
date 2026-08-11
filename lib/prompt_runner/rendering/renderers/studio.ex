defmodule PromptRunner.Rendering.Renderers.StudioRenderer do
  @moduledoc """
  CLI-grade interactive renderer for prompt-runner canonical events.
  """

  @behaviour PromptRunner.Rendering.Renderer

  alias PromptRunner.Rendering.Studio.ANSI
  alias PromptRunner.Rendering.Studio.Diff
  alias PromptRunner.Rendering.Studio.ToolSummary

  @type state :: %{
          color: boolean(),
          tool_output: :summary | :preview | :full,
          show_spinner: boolean(),
          indent: non_neg_integer(),
          is_tty: boolean(),
          phase: :idle | :text | :tool,
          streamed_assistant?: boolean(),
          current_tool: map() | nil,
          tool_count: non_neg_integer(),
          event_count: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer()
        }

  @impl true
  def init(opts) do
    is_tty = Keyword.get(opts, :tty, ANSI.tty?())
    tool_output = normalize_tool_output(Keyword.get(opts, :tool_output, :summary))

    {:ok,
     %{
       color: Keyword.get(opts, :color, true),
       tool_output: tool_output,
       thinking: Keyword.get(opts, :thinking, :show),
       diff: normalize_diff(Keyword.get(opts, :diff, :stat)),
       cwd: Keyword.get(opts, :cwd),
       show_spinner: Keyword.get(opts, :show_spinner, true),
       indent: Keyword.get(opts, :indent, 2),
       is_tty: is_tty,
       phase: :idle,
       streamed_assistant?: false,
       current_tool: nil,
       tool_count: 0,
       event_count: 0,
       total_input_tokens: 0,
       total_output_tokens: 0
     }}
  end

  @impl true
  def render_event(%{hidden?: true}, state), do: {:ok, [], state}

  def render_event(
        %{type: :message_streamed, data: %{kind: :thinking}},
        %{thinking: :hide} = state
      ),
      do: {:ok, [], state}

  def render_event(event, state) do
    state = %{state | event_count: state.event_count + 1}
    {iodata, new_state} = render(event, state)
    {:ok, iodata, new_state}
  end

  @impl true
  def finish(state), do: {:ok, [], state}

  # A view change lands between events, so it takes effect from the next event
  # onwards and never reformats what has already been written. Only the keys
  # actually named change; a caller raising tool output must not reset anything
  # else it did not mention.
  @impl true
  def set_view(view, state) when is_map(view) do
    state =
      case Map.fetch(view, :tool_output) do
        {:ok, tool_output} -> %{state | tool_output: normalize_tool_output(tool_output)}
        :error -> state
      end

    state =
      case Map.fetch(view, :thinking) do
        {:ok, thinking} when thinking in [:show, :hide] -> %{state | thinking: thinking}
        _other -> state
      end

    state =
      case Map.fetch(view, :diff) do
        {:ok, diff} -> %{state | diff: normalize_diff(diff)}
        :error -> state
      end

    {:ok, state}
  end

  # "unknown session started" was this renderer reporting a gap it could not
  # fill: the model is named on the launched argv, but nothing put it in the
  # event. It does now -- and if a provider ever genuinely does not name one,
  # say so rather than printing "unknown" where a model name belongs.
  defp render(%{type: :run_started, data: data}, state) do
    icon = ANSI.blue(ANSI.info(), state.color)
    line = ["\n", indent(state), icon, " ", session_started_label(data), "\n"]
    {line, %{state | phase: :idle, streamed_assistant?: false}}
  end

  defp render(%{type: :message_streamed, data: data}, state) do
    text = map_get(data, :delta) || map_get(data, :content) || ""
    thinking? = map_get(data, :kind) == :thinking

    {render_text(text, state),
     %{state | phase: :text, streamed_assistant?: state.streamed_assistant? or not thinking?}}
  end

  defp render(%{type: :tool_call_started, data: data}, state) do
    {close_text, state} = close_text_block(state)
    name = map_get(data, :tool_name) || "tool"
    input = map_get(data, :tool_input) || %{}
    spinner_text = ToolSummary.spinner_text(%{name: name, input: input})
    symbol = running_symbol(state)

    line =
      [indent(state), symbol, " ", spinner_text]
      |> maybe_newline(!state.is_tty)

    tool_state = %{name: name, id: map_get(data, :tool_call_id), input: input}

    {[close_text, line],
     %{state | phase: :tool, current_tool: tool_state, tool_count: state.tool_count + 1}}
  end

  defp render(%{type: type, data: data}, state)
       when type in [:tool_call_completed, :tool_call_failed] do
    tool_info = build_tool_info(state.current_tool, data, type)
    summary = ToolSummary.summary_line(tool_info)
    icon = status_icon(tool_info, state)
    clear = if state.is_tty, do: ANSI.clear_line(), else: []
    line = [indent(state), icon, " ", summary, diff_stat(tool_info, state), "\n"]
    extras = [render_tool_output(tool_info, state), render_diff(tool_info, state)]

    {[clear, line, extras], %{state | phase: :idle, current_tool: nil}}
  end

  defp render(%{type: :token_usage_updated, data: data}, state) do
    input_tokens = map_get(data, :input_tokens) || 0
    output_tokens = map_get(data, :output_tokens) || 0

    {[],
     %{
       state
       | total_input_tokens: input_tokens,
         total_output_tokens: output_tokens
     }}
  end

  # A provider either streams a message as deltas or delivers it whole. Claude
  # streams, so printing the completed message too would double it. Codex does
  # not stream at all -- suppressing this unconditionally, as this renderer used
  # to, left a Codex run with nothing on screen but "session started".
  #
  # So the test is what actually reached the screen, not which provider sent it.
  # Reasoning text does not count: it is displayed, but it is not the message.
  defp render(%{type: :message_received, data: data}, %{streamed_assistant?: false} = state) do
    text = map_get(data, :content) || ""
    {render_text(text, state), %{state | phase: :text, streamed_assistant?: false}}
  end

  defp render(%{type: :message_received}, state),
    do: {[], %{state | streamed_assistant?: false}}

  defp render(%{type: :run_completed, data: data}, state) do
    {close_text, state} = close_text_block(state)
    reason = map_get(data, :stop_reason) || "unknown"
    {input_tokens, output_tokens} = final_token_usage(data, state)
    icon = ANSI.blue(ANSI.info(), state.color)

    line = [
      "\n",
      indent(state),
      icon,
      " Session complete (",
      to_string(reason),
      ") — ",
      Integer.to_string(input_tokens),
      "/",
      Integer.to_string(output_tokens),
      " tokens, ",
      Integer.to_string(state.tool_count),
      " tools\n"
    ]

    {[close_text, line], %{state | phase: :idle}}
  end

  defp render(%{type: :run_failed, data: data}, state) do
    {close_text, state} = close_text_block(state)
    message = map_get(data, :error_message) || "unknown error"
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, "\n", indent(state), icon, " ", message, "\n"], %{state | phase: :idle}}
  end

  defp render(%{type: :run_cancelled}, state) do
    {close_text, state} = close_text_block(state)
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, "\n", indent(state), icon, " cancelled\n"], %{state | phase: :idle}}
  end

  defp render(%{type: :error_occurred, data: data}, state) do
    {close_text, state} = close_text_block(state)
    message = map_get(data, :error_message) || "unknown error"
    icon = ANSI.red(ANSI.failure(), state.color)
    {[close_text, indent(state), icon, " ", message, "\n"], %{state | phase: :idle}}
  end

  defp render(%{type: type}, state) do
    {close_text, state} = close_text_block(state)
    label = ANSI.dim("? #{type}", state.color)
    {[close_text, indent(state), label, "\n"], %{state | phase: :idle}}
  end

  defp session_started_label(data) do
    case {map_get(data, :model), map_get(data, :reasoning_effort)} do
      {nil, _} -> "session started"
      {model, nil} -> "#{model} session started"
      {model, effort} -> "#{model} (#{effort}) session started"
    end
  end

  defp render_text("", _state), do: []
  defp render_text(text, %{phase: :text}), do: text
  defp render_text(text, state), do: ["\n", indent(state), text]

  defp close_text_block(%{phase: :text} = state), do: {"\n", %{state | phase: :idle}}
  defp close_text_block(state), do: {[], state}

  # A stat suffix, and only for a change that actually carries one. A tool whose
  # event names a path and nothing else has no counts to show and must not
  # imply it does.
  defp diff_stat(_tool_info, %{diff: :none}), do: []
  defp diff_stat(tool_info, _state), do: Diff.stat_suffix(tool_info)

  defp render_diff(_tool_info, %{diff: diff}) when diff in [:none, :stat], do: []

  defp render_diff(tool_info, %{diff: :full} = state) do
    Diff.render(tool_info,
      color: state.color,
      indent: state.indent + 2,
      cwd: state.cwd
    )
  end

  defp normalize_diff(diff) when diff in [:none, :stat, :full], do: diff
  defp normalize_diff(_diff), do: :stat

  defp render_tool_output(_tool_info, %{tool_output: :summary}), do: []

  defp render_tool_output(tool_info, %{tool_output: :preview} = state) do
    tool_info
    |> ToolSummary.preview_lines(3)
    |> prefixed_lines("│", state)
  end

  defp render_tool_output(tool_info, %{tool_output: :full} = state) do
    output = normalize_output(Map.get(tool_info, :output))

    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> prefixed_lines("┊", state)
  end

  defp prefixed_lines([], _prefix, _state), do: []

  defp prefixed_lines(lines, prefix, state) do
    line_indent = String.duplicate(" ", state.indent + 2)
    dim_prefix = ANSI.dim(prefix, state.color)

    Enum.map(lines, fn line ->
      [line_indent, dim_prefix, " ", ANSI.dim(line, state.color), "\n"]
    end)
  end

  # The event *type* is the first authority on whether a call failed. It used to
  # be ignored entirely: a `:tool_call_failed` carries `is_error: true` and
  # usually no `status` or `exit_code`, so a failed call rendered with a success
  # icon and a success verb.
  defp build_tool_info(current_tool, data, type) do
    name = map_get(data, :tool_name) || map_get(current_tool, :name) || "tool"
    input = map_get(data, :tool_input) || map_get(current_tool, :input) || %{}
    output = map_get(data, :tool_output)
    exit_code = map_get(data, :exit_code) || map_get(output, :exit_code)
    duration_ms = map_get(data, :duration_ms) || map_get(output, :duration_ms)

    status = tool_status(type, data, output, exit_code)

    %{
      name: name,
      input: input,
      output: output,
      exit_code: exit_code,
      duration_ms: duration_ms,
      status: status
    }
  end

  defp tool_status(:tool_call_failed, _data, _output, _exit_code), do: :failed

  defp tool_status(_type, data, output, exit_code) do
    if map_get(data, :is_error) == true do
      :failed
    else
      normalize_status(map_get(data, :status) || map_get(output, :status), exit_code)
    end
  end

  defp status_icon(%{status: :failed}, state), do: ANSI.red(ANSI.failure(), state.color)
  defp status_icon(_, state), do: ANSI.green(ANSI.success(), state.color)

  defp running_symbol(%{show_spinner: false} = state), do: ANSI.blue(ANSI.info(), state.color)
  defp running_symbol(state), do: ANSI.cyan(ANSI.running(), state.color)

  defp final_token_usage(data, state) do
    if state.total_input_tokens == 0 and state.total_output_tokens == 0 do
      usage = map_get(data, :token_usage) || %{}
      {map_get(usage, :input_tokens) || 0, map_get(usage, :output_tokens) || 0}
    else
      {state.total_input_tokens, state.total_output_tokens}
    end
  end

  defp normalize_status(status, _exit_code) when status in [:failed, "failed"], do: :failed

  defp normalize_status(_status, exit_code) when is_integer(exit_code) and exit_code != 0,
    do: :failed

  defp normalize_status(_, _), do: :completed

  defp normalize_tool_output(mode) when mode in [:summary, :preview, :full], do: mode
  defp normalize_tool_output(_), do: :summary

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp normalize_output(nil), do: ""
  defp normalize_output(output) when is_binary(output), do: output
  defp normalize_output(%{output: output}), do: normalize_output(output)
  defp normalize_output(%{"output" => output}), do: normalize_output(output)
  defp normalize_output(output) when is_map(output), do: inspect(output)
  defp normalize_output(output), do: to_string(output)

  defp maybe_newline(parts, true), do: [parts, "\n"]
  defp maybe_newline(parts, false), do: parts

  defp indent(state), do: String.duplicate(" ", state.indent)
end
