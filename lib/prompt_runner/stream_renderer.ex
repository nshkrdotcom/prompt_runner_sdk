defmodule PromptRunner.StreamRenderer do
  @moduledoc false

  alias ClaudeCodeSDK.Message

  @red "\e[0;31m"
  @green "\e[0;32m"
  @yellow "\e[1;33m"
  @blue "\e[0;34m"
  @cyan "\e[0;36m"
  @magenta "\e[0;35m"
  @dim "\e[2m"
  @nc "\e[0m"

  @tool_preview_limit 120
  @result_preview_limit 2000

  @type loggers :: %{text_io: IO.device(), events_io: IO.device(), events_mode: atom()}

  @spec stream(Enumerable.t(), loggers(), map(), %{mode: atom(), meta: atom()}) ::
          :ok | {:error, term()}
  def stream(stream, loggers, context, log_config) do
    initial_state = %{
      status: :ok,
      in_text: false,
      in_message: false,
      line_open: false,
      streaming: nil,
      message_count: 0,
      event_count: 0,
      tool_count: 0,
      tool_input: "",
      current_tool: nil,
      current_tool_id: nil,
      last_stop_reason: nil,
      last_message_token: nil,
      log_mode: log_config.mode,
      log_meta: log_config.meta
    }

    log_event_json(loggers, %{type: :session_start, context: context})

    final_state =
      Enum.reduce(stream, initial_state, fn event, state ->
        state = %{state | event_count: state.event_count + 1}
        log_event_json(loggers, event)
        handle_event(event, state, loggers)
      end)

    log_event_json(loggers, %{type: :session_end, summary: session_summary(final_state)})

    case final_state.status do
      :ok -> :ok
      other -> other
    end
  end

  def compact_legend_line do
    compact_join([
      dim_text("legend:"),
      token_msg("m:") <> token_role("s") <> "=system",
      token_msg("m:") <> token_role("u") <> "=user",
      token_msg("m:") <> token_role("a") <> "=assistant",
      token_msg("m+") <> "=start",
      token_msg("m-") <> "=stop",
      token_msg("tb+") <> "=text_block",
      token_msg("cb-") <> "=content_block",
      token_msg("md") <> "=delta",
      token_tool("t+") <> "=tool_start",
      token_tool("t-") <> "=tool_end",
      token_stream(">>") <> "=text",
      token_delta("<<") <> "=tool_input"
    ])
  end

  defp handle_event(event, %{log_mode: :compact} = state, loggers) do
    handle_event_compact(event, state, loggers)
  end

  defp handle_event(event, state, loggers) do
    handle_event_verbose(event, state, loggers)
  end

  defp handle_event_compact(%{type: :text_delta, text: text}, state, loggers) do
    state =
      compact_begin_stream(state, loggers, :assistant_text, stream_prefix(:assistant_text, state))

    state = compact_emit_raw(loggers, state, text)
    %{state | in_text: true}
  end

  defp handle_event_compact(
         %{type: :message_start, model: model, role: role} = event,
         state,
         loggers
       ) do
    state = compact_end_stream(state, loggers)
    token = compact_message_start_token(model, role) <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)
    %{state | message_count: state.message_count + 1, in_message: true}
  end

  defp handle_event_compact(%{type: :text_block_start} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    token = token_msg("tb+") <> compact_meta_suffix(event, state.log_meta)
    compact_emit_token(loggers, state, token)
  end

  defp handle_event_compact(%{type: :thinking_start} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    token = token_thinking("th+") <> compact_meta_suffix(event, state.log_meta)
    compact_emit_token(loggers, state, token)
  end

  defp handle_event_compact(%{type: :thinking_delta, thinking: thinking} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    payload = dim_text(truncate(thinking, @tool_preview_limit))
    token = token_thinking("th:") <> payload <> compact_meta_suffix(event, state.log_meta)
    compact_emit_token(loggers, state, token)
  end

  defp handle_event_compact(%{type: :tool_use_start, name: name, id: id} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    token = token_tool("t+#{name}") <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)

    %{
      state
      | tool_count: state.tool_count + 1,
        tool_input: "",
        current_tool: name,
        current_tool_id: id
    }
  end

  defp handle_event_compact(%{type: :tool_input_delta} = event, state, loggers) do
    json_chunk = Map.get(event, :json) || Map.get(event, :input) || ""

    case json_chunk do
      "" ->
        state

      _ ->
        state =
          compact_begin_stream(state, loggers, :tool_input, stream_prefix(:tool_input, state))

        chunk = dim_text(truncate(json_chunk, @tool_preview_limit))
        state = compact_emit_raw(loggers, state, chunk)
        %{state | tool_input: state.tool_input <> json_chunk}
    end
  end

  defp handle_event_compact(
         %{type: :tool_complete, tool_name: tool_name, result: result} = event,
         state,
         loggers
       ) do
    state = compact_end_stream(state, loggers)
    token = token_tool("t-#{tool_name}") <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)

    state =
      case result do
        nil ->
          state

        "" ->
          state

        _ ->
          compact_emit_token(
            loggers,
            state,
            token_tool("tr:") <> dim_text(format_value(result, @result_preview_limit))
          )
      end

    %{state | tool_input: "", current_tool: nil, current_tool_id: nil}
  end

  defp handle_event_compact(%{type: :tool_complete, tool_name: tool_name} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    token = token_tool("t-#{tool_name}") <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)
    %{state | tool_input: "", current_tool: nil, current_tool_id: nil}
  end

  defp handle_event_compact(
         %{type: :content_block_stop, final_text: final_text} = event,
         state,
         loggers
       ) do
    state = compact_end_stream(state, loggers)
    token = token_msg("cb-") <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)

    state =
      if final_text not in [nil, ""] and state.in_text == false do
        compact_emit_token(
          loggers,
          state,
          token_msg("ft:") <> dim_text(truncate(final_text, @tool_preview_limit))
        )
      else
        state
      end

    state
  end

  defp handle_event_compact(%{type: :message_delta, stop_reason: reason} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    reason_label = short_reason(reason)

    token =
      token_msg("md" <> if(reason_label == "", do: "", else: ":#{reason_label}")) <>
        compact_meta_suffix(event, state.log_meta)

    state = compact_emit_token(loggers, state, token)
    %{state | last_stop_reason: reason}
  end

  defp handle_event_compact(%{type: :message_stop} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    reason = Map.get(event, :stop_reason, state.last_stop_reason)
    reason_label = short_reason(reason)

    token =
      token_msg("m-" <> if(reason_label == "", do: "", else: ":#{reason_label}")) <>
        compact_meta_suffix(event, state.log_meta)

    state = compact_emit_token(loggers, state, token)

    state =
      if Map.has_key?(event, :final_text) and event.final_text not in [nil, ""] and
           state.in_text == false do
        compact_emit_token(
          loggers,
          state,
          token_msg("ft:") <> dim_text(format_value(event.final_text, @result_preview_limit))
        )
      else
        state
      end

    state =
      if Map.has_key?(event, :structured_output) and event.structured_output not in [nil, ""] do
        compact_emit_token(
          loggers,
          state,
          token_msg("so:") <>
            dim_text(format_value(event.structured_output, @result_preview_limit))
        )
      else
        state
      end

    state =
      if Map.has_key?(event, :error) and event.error != nil do
        compact_emit_token(loggers, state, token_error("ae:") <> dim_text(inspect(event.error)))
      else
        state
      end

    %{state | in_text: false, in_message: false, last_stop_reason: nil}
  end

  defp handle_event_compact(
         %{type: :message, message: %Message{} = message} = event,
         state,
         loggers
       ) do
    state = compact_end_stream(state, loggers)
    raw_token = compact_message_token_raw(message)

    if raw_token == "" or raw_token == state.last_message_token do
      state
    else
      token = compact_message_token(message) <> compact_meta_suffix(event, state.log_meta)
      state = compact_emit_token(loggers, state, token)
      %{state | last_message_token: raw_token}
    end
  end

  defp handle_event_compact(%{type: :error, error: error} = event, state, loggers) do
    state = compact_end_stream(state, loggers)
    token = token_error("!" <> inspect(error)) <> compact_meta_suffix(event, state.log_meta)
    state = compact_emit_token(loggers, state, token)
    %{state | status: {:error, error}}
  end

  defp handle_event_compact(
         %{type: :error, error_type: error_type, message: message} = event,
         state,
         loggers
       ) do
    state = compact_end_stream(state, loggers)

    token =
      token_error("!" <> inspect(error_type) <> " " <> inspect(message)) <>
        compact_meta_suffix(event, state.log_meta)

    state = compact_emit_token(loggers, state, token)
    %{state | status: {:error, {error_type, message}}}
  end

  defp handle_event_compact(event, state, loggers) do
    state = compact_end_stream(state, loggers)

    token =
      token_dim("?") <>
        dim_text(truncate(inspect(event), @tool_preview_limit)) <>
        compact_meta_suffix(event, state.log_meta)

    compact_emit_token(loggers, state, token)
  end

  defp handle_event_verbose(%{type: :text_delta, text: text}, state, loggers) do
    emit_text(loggers, text)
    %{state | in_text: true}
  end

  defp handle_event_verbose(
         %{type: :message_start, model: model, role: role} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)
    usage = Map.get(event, :usage)

    usage_info =
      if usage in [nil, %{}], do: "", else: " usage=#{format_value(usage, @tool_preview_limit)}"

    line =
      "[message_start] model=#{inspect(model)} role=#{inspect(role)}#{usage_info}#{format_meta(event, state.log_meta)}"

    emit_line(loggers, line)
    %{state | message_count: state.message_count + 1}
  end

  defp handle_event_verbose(%{type: :text_block_start} = event, state, loggers) do
    state = maybe_break_line(state, loggers)
    emit_line(loggers, "[text_block_start]#{format_meta(event, state.log_meta)}")
    state
  end

  defp handle_event_verbose(%{type: :thinking_start} = event, state, loggers) do
    state = maybe_break_line(state, loggers)
    emit_line(loggers, "[thinking_start]#{format_meta(event, state.log_meta)}")
    state
  end

  defp handle_event_verbose(%{type: :thinking_delta, thinking: thinking} = event, state, loggers) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[thinking_delta] #{truncate(thinking, @tool_preview_limit)}#{format_meta(event, state.log_meta)}"
    )

    state
  end

  defp handle_event_verbose(%{type: :tool_use_start, name: name, id: id} = event, state, loggers) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[tool_use_start] name=#{name} id=#{id}#{format_meta(event, state.log_meta)}"
    )

    %{
      state
      | tool_count: state.tool_count + 1,
        tool_input: "",
        current_tool: name,
        current_tool_id: id
    }
  end

  defp handle_event_verbose(%{type: :tool_input_delta} = event, state, loggers) do
    json_chunk = Map.get(event, :json) || Map.get(event, :input) || ""
    state = maybe_break_line(state, loggers)

    if json_chunk != "" do
      emit_line(
        loggers,
        "[tool_input_delta] #{truncate(json_chunk, @tool_preview_limit)}#{format_meta(event, state.log_meta)}"
      )
    else
      emit_line(loggers, "[tool_input_delta] (empty)#{format_meta(event, state.log_meta)}")
    end

    %{state | tool_input: state.tool_input <> json_chunk}
  end

  defp handle_event_verbose(
         %{type: :tool_complete, tool_name: tool_name, result: result} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[tool_complete] name=#{tool_name} id=#{state.current_tool_id}#{format_meta(event, state.log_meta)}"
    )

    display_tool_execution(state.current_tool, state.tool_input, result, loggers)

    %{state | tool_input: "", current_tool: nil, current_tool_id: nil}
  end

  defp handle_event_verbose(%{type: :tool_complete, tool_name: tool_name} = event, state, loggers) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[tool_complete] name=#{tool_name} id=#{state.current_tool_id}#{format_meta(event, state.log_meta)}"
    )

    display_tool_execution(state.current_tool, state.tool_input, nil, loggers)

    %{state | tool_input: "", current_tool: nil, current_tool_id: nil}
  end

  defp handle_event_verbose(
         %{type: :content_block_stop, final_text: final_text} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[content_block_stop] final_text=#{truncate(final_text, @tool_preview_limit)}#{format_meta(event, state.log_meta)}"
    )

    state
  end

  defp handle_event_verbose(
         %{type: :message_delta, stop_reason: reason, stop_sequence: sequence} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[message_delta] stop_reason=#{inspect(reason)} stop_sequence=#{inspect(sequence)}#{format_meta(event, state.log_meta)}"
    )

    %{state | last_stop_reason: reason}
  end

  defp handle_event_verbose(%{type: :message_stop} = event, state, loggers) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[message_stop] stop_reason=#{inspect(state.last_stop_reason)}#{format_meta(event, state.log_meta)}"
    )

    if Map.has_key?(event, :final_text) do
      emit_line(loggers, "[final_text] #{format_value(event.final_text, @result_preview_limit)}")
    end

    if Map.has_key?(event, :structured_output) do
      emit_line(
        loggers,
        "[structured_output] #{format_value(event.structured_output, @result_preview_limit)}"
      )
    end

    if Map.has_key?(event, :error) and event.error != nil do
      emit_line(loggers, "[assistant_error] #{inspect(event.error)}")
    end

    %{state | in_text: false, last_stop_reason: nil}
  end

  defp handle_event_verbose(
         %{type: :message, message: %Message{} = message} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[message] type=#{message.type} subtype=#{inspect(message.subtype)}#{format_meta(event, state.log_meta)}"
    )

    state
  end

  defp handle_event_verbose(%{type: :error, error: error} = event, state, loggers) do
    state = maybe_break_line(state, loggers)
    emit_line(loggers, "[error] #{inspect(error)}#{format_meta(event, state.log_meta)}")
    %{state | status: {:error, error}}
  end

  defp handle_event_verbose(
         %{type: :error, error_type: error_type, message: message} = event,
         state,
         loggers
       ) do
    state = maybe_break_line(state, loggers)

    emit_line(
      loggers,
      "[error] #{inspect(error_type)} #{inspect(message)}#{format_meta(event, state.log_meta)}"
    )

    %{state | status: {:error, {error_type, message}}}
  end

  defp handle_event_verbose(event, state, loggers) do
    state = maybe_break_line(state, loggers)
    emit_line(loggers, "[event] #{inspect(event)}")
    state
  end

  defp log_event_json(loggers, event) do
    mode = Map.get(loggers, :events_mode, :full)

    case mode do
      :off ->
        :ok

      :full ->
        entry = %{
          ts: DateTime.utc_now() |> DateTime.to_iso8601(),
          event: sanitize_event(event)
        }

        IO.binwrite(loggers.events_io, Jason.encode!(entry) <> "\n")

      :compact ->
        entry = compact_event_entry(event)
        IO.binwrite(loggers.events_io, Jason.encode!(entry) <> "\n")
    end
  end

  defp sanitize_event(%{message: %Message{} = msg} = event) do
    message = %{
      type: msg.type,
      subtype: msg.subtype,
      data: msg.data,
      raw: msg.raw
    }

    Map.put(event, :message, message)
  end

  defp sanitize_event(event), do: event

  defp compact_event_entry(event) do
    %{
      t: System.system_time(:millisecond),
      e: compact_event(event)
    }
  end

  defp compact_event(%{type: :session_start, context: %{prompt: prompt}}) when is_map(prompt) do
    %{
      "t" => short_event_type(:session_start),
      "p" => Map.get(prompt, :num)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :session_start}) do
    %{"t" => short_event_type(:session_start)}
  end

  defp compact_event(%{type: :session_end, summary: summary}) when is_map(summary) do
    %{
      "t" => short_event_type(:session_end),
      "e" => Map.get(summary, :event_count),
      "m" => Map.get(summary, :message_count),
      "tl" => Map.get(summary, :tool_count)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :message_start, model: model, role: role}) do
    %{
      "t" => short_event_type(:message_start),
      "r" => short_role(role),
      "m" => short_model(model)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :text_delta, text: text}) do
    %{
      "t" => short_event_type(:text_delta),
      "l" => text_length(text)
    }
  end

  defp compact_event(%{type: :text_block_start}) do
    %{"t" => short_event_type(:text_block_start)}
  end

  defp compact_event(%{type: :thinking_start}) do
    %{"t" => short_event_type(:thinking_start)}
  end

  defp compact_event(%{type: :thinking_delta, thinking: thinking}) do
    %{
      "t" => short_event_type(:thinking_delta),
      "l" => text_length(thinking)
    }
  end

  defp compact_event(%{type: :tool_use_start, name: name}) do
    %{
      "t" => short_event_type(:tool_use_start),
      "n" => name
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :tool_input_delta} = event) do
    chunk = Map.get(event, :json) || Map.get(event, :input) || ""

    %{
      "t" => short_event_type(:tool_input_delta),
      "l" => text_length(chunk)
    }
  end

  defp compact_event(%{type: :tool_complete, tool_name: tool_name, result: result}) do
    %{
      "t" => short_event_type(:tool_complete),
      "n" => tool_name,
      "l" => text_length(result)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :content_block_stop, final_text: final_text}) do
    %{
      "t" => short_event_type(:content_block_stop),
      "l" => text_length(final_text)
    }
  end

  defp compact_event(%{type: :message_delta, stop_reason: reason}) do
    %{
      "t" => short_event_type(:message_delta),
      "sr" => short_reason(reason)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :message_stop, stop_reason: reason}) do
    %{
      "t" => short_event_type(:message_stop),
      "sr" => short_reason(reason)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :message, message: %Message{} = message}) do
    {type_label, subtype_label} = message_type_labels(message)

    %{
      "t" => short_event_type(:message),
      "mt" => type_label,
      "st" => if(subtype_label == "", do: nil, else: subtype_label)
    }
    |> drop_nil_values()
  end

  defp compact_event(%{type: :error, error: error}) do
    %{
      "t" => short_event_type(:error),
      "x" => truncate(inspect(error), @tool_preview_limit)
    }
  end

  defp compact_event(%{type: :error, error_type: error_type, message: message}) do
    %{
      "t" => short_event_type(:error),
      "x" => truncate("#{inspect(error_type)} #{inspect(message)}", @tool_preview_limit)
    }
  end

  defp compact_event(event) do
    %{
      "t" => short_event_type(Map.get(event, :type)),
      "x" => truncate(inspect(event), @tool_preview_limit)
    }
  end

  @spec emit_line(loggers(), String.t()) :: :ok
  def emit_line(loggers, line) do
    IO.puts(line)
    IO.binwrite(loggers.text_io, strip_ansi(line) <> "\n")
    :ok
  end

  defp emit_text(loggers, text) do
    IO.write(text)
    IO.binwrite(loggers.text_io, strip_ansi(text))
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*m/, "")
  end

  defp compact_emit_token(loggers, state, token) do
    prefix = if state.line_open, do: " ", else: ""
    emit_text(loggers, prefix <> token)
    %{state | line_open: true}
  end

  defp compact_emit_raw(loggers, state, text) do
    emit_text(loggers, text)
    clean = strip_ansi(text)
    %{state | line_open: not String.ends_with?(clean, "\n")}
  end

  defp compact_begin_stream(state, loggers, stream_type, prefix) do
    state =
      if state.streaming != stream_type do
        compact_end_stream(state, loggers)
      else
        state
      end

    state =
      if state.streaming == nil and state.line_open do
        emit_text(loggers, " ")
        %{state | line_open: true}
      else
        state
      end

    if state.streaming == stream_type do
      state
    else
      state = compact_emit_raw(loggers, state, prefix)
      %{state | streaming: stream_type}
    end
  end

  defp compact_end_stream(%{streaming: nil} = state, _loggers), do: state

  defp compact_end_stream(state, loggers) do
    state =
      if state.line_open do
        emit_text(loggers, "\n")
        %{state | line_open: false}
      else
        state
      end

    %{state | streaming: nil}
  end

  defp maybe_break_line(%{in_text: true} = state, loggers) do
    emit_line(loggers, "")
    %{state | in_text: false}
  end

  defp maybe_break_line(state, _loggers), do: state

  defp format_meta(_event, meta_mode) when meta_mode in [nil, :none], do: ""

  defp format_meta(event, _meta_mode) do
    meta =
      [
        {:session_id, Map.get(event, :session_id)},
        {:uuid, Map.get(event, :uuid)},
        {:parent_tool_use_id, Map.get(event, :parent_tool_use_id)}
      ]
      |> Enum.filter(fn {_k, v} -> v not in [nil, ""] end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    if meta == "", do: "", else: " #{meta}"
  end

  defp colorize(text, color) when is_binary(text) do
    if text == "" do
      ""
    else
      color <> text <> @nc
    end
  end

  defp dim_text(text), do: colorize(text, @dim)
  defp token_msg(text), do: colorize(text, @blue)
  defp token_role(text), do: colorize(text, @cyan)
  defp token_model(text), do: colorize(text, @magenta)
  defp token_stream(text), do: colorize(text, @magenta)
  defp token_tool(text), do: colorize(text, @green)
  defp token_delta(text), do: colorize(text, @yellow)
  defp token_thinking(text), do: colorize(text, @yellow)
  defp token_error(text), do: colorize(text, @red)
  defp token_dim(text), do: colorize(text, @dim)

  defp compact_join(parts) do
    parts
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.join(" ")
  end

  defp compact_meta_suffix(event, meta_mode) do
    meta = format_meta(event, meta_mode)
    if meta == "", do: "", else: dim_text(meta)
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.into(%{})
  end

  defp stream_prefix(:assistant_text, _state) do
    token_stream(">>") <> " "
  end

  defp stream_prefix(:tool_input, state) do
    tool_label =
      if state.current_tool in [nil, ""] do
        ""
      else
        token_tool(state.current_tool)
      end

    prefix = compact_join([token_delta("<<"), tool_label])
    if prefix == "", do: "", else: prefix <> " "
  end

  defp compact_message_start_token(model, role) do
    role_label = short_role(role)
    model_label = short_model(model)

    compact_join([
      token_msg("m+"),
      token_role(role_label),
      token_model(model_label)
    ])
  end

  defp compact_message_token(%Message{} = message) do
    {type_label, subtype_label} = message_type_labels(message)
    token_msg("m:") <> token_role(type_label) <> dim_text(subtype_label)
  end

  defp compact_message_token_raw(%Message{} = message) do
    {type_label, subtype_label} = message_type_labels(message)

    if type_label == "" do
      ""
    else
      "m:#{type_label}#{subtype_label}"
    end
  end

  defp message_type_labels(%Message{type: type, subtype: subtype}) do
    type_label = short_message_type(type)
    subtype_label = if subtype in [nil, ""], do: "", else: ":#{subtype}"
    {type_label, subtype_label}
  end

  defp short_role(nil), do: ""
  defp short_role(role) when is_atom(role), do: short_role(Atom.to_string(role))

  defp short_role(role) when is_binary(role) do
    case String.downcase(role) do
      "assistant" -> "a"
      "user" -> "u"
      "system" -> "s"
      other -> String.first(other) || ""
    end
  end

  defp short_message_type(nil), do: ""
  defp short_message_type(type) when is_atom(type), do: short_message_type(Atom.to_string(type))

  defp short_message_type(type) when is_binary(type) do
    case String.downcase(type) do
      "assistant" -> "a"
      "user" -> "u"
      "system" -> "s"
      other -> String.first(other) || ""
    end
  end

  defp short_model(nil), do: ""
  defp short_model(model) when is_atom(model), do: short_model(Atom.to_string(model))

  defp short_model(model) when is_binary(model) do
    model
    |> String.replace_prefix("claude-", "")
    |> String.replace_prefix("anthropic.", "")
    |> String.split("-", trim: true)
    |> Enum.take(3)
    |> Enum.join("-")
  end

  defp short_reason(nil), do: ""
  defp short_reason(reason) when is_atom(reason), do: short_reason(Atom.to_string(reason))

  defp short_reason(reason) when is_binary(reason) do
    case String.downcase(reason) do
      "tool_use" -> "tool"
      "end_turn" -> "end"
      other -> other
    end
  end

  defp short_event_type(nil), do: "ev"
  defp short_event_type(type) when is_atom(type), do: short_event_type(Atom.to_string(type))

  @event_type_labels %{
    "session_start" => "ss",
    "session_end" => "se",
    "message_start" => "ms",
    "message_stop" => "m-",
    "message_delta" => "md",
    "message" => "m",
    "text_delta" => "td",
    "text_block_start" => "tb",
    "content_block_stop" => "cb",
    "thinking_start" => "ts",
    "thinking_delta" => "th",
    "tool_use_start" => "tu",
    "tool_input_delta" => "ti",
    "tool_complete" => "tc",
    "error" => "e"
  }

  defp short_event_type(type) when is_binary(type) do
    Map.get(@event_type_labels, type, "ev")
  end

  defp text_length(nil), do: nil
  defp text_length(text) when is_binary(text), do: byte_size(text)

  defp text_length(text) do
    case Jason.encode(text) do
      {:ok, json} -> byte_size(json)
      _ -> byte_size(inspect(text))
    end
  end

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp format_value(value, limit) when is_binary(value) do
    truncate(value, limit)
  end

  defp format_value(value, limit) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> truncate(json, limit)
      _ -> truncate(inspect(value), limit)
    end
  end

  defp format_value(value, limit) do
    truncate(inspect(value), limit)
  end

  defp session_summary(state) do
    %{
      event_count: state.event_count,
      message_count: state.message_count,
      tool_count: state.tool_count
    }
  end

  defp display_tool_execution(tool_name, tool_input, result, loggers) do
    input_map = decode_tool_input(tool_input)

    if input_map != nil do
      emit_line(
        loggers,
        "[tool_input] #{tool_name}: #{format_value(input_map, @result_preview_limit)}"
      )
    end

    if result not in [nil, ""] do
      emit_line(
        loggers,
        "[tool_result] #{tool_name}: #{format_value(result, @result_preview_limit)}"
      )
    end

    emit_line(loggers, "[tool_done] #{tool_name}")
  end

  defp decode_tool_input(tool_input) when is_binary(tool_input) do
    if tool_input == "" do
      nil
    else
      case Jason.decode(tool_input) do
        {:ok, input_map} -> input_map
        _ -> %{"raw" => tool_input}
      end
    end
  end
end
