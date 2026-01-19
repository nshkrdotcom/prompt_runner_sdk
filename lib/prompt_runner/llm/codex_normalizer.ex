defmodule PromptRunner.LLM.CodexNormalizer do
  @moduledoc false

  alias Codex.Events
  alias Codex.Items

  @type state :: %{
          assistant_delta?: boolean(),
          started_tools: map(),
          seq: non_neg_integer()
        }

  @spec normalize(Enumerable.t(), String.t() | nil) :: Enumerable.t()
  def normalize(raw_stream, model) do
    init = %{assistant_delta?: false, started_tools: %{}, seq: 0}

    Stream.transform(raw_stream, init, fn event, st ->
      {events, st} = event_to_events(event, st, model)
      {events, st}
    end)
  end

  defp event_to_events(event, st, model) do
    handlers = [
      &turn_event_to_events/3,
      &message_event_to_events/3,
      &item_event_to_events/3,
      &tool_call_event_to_events/3
    ]

    Enum.reduce_while(handlers, :unhandled, fn handler, _acc ->
      case handler.(event, st, model) do
        :unhandled -> {:cont, :unhandled}
        {:ok, result} -> {:halt, result}
      end
    end)
    |> case do
      :unhandled -> {[], st}
      result -> result
    end
  end

  defp turn_event_to_events(%Events.TurnStarted{}, st, model) do
    st = %{st | assistant_delta?: false, started_tools: %{}}
    {:ok, {[%{type: :message_start, model: model, role: "assistant"}], st}}
  end

  defp turn_event_to_events(%Events.TurnCompleted{}, st, _model) do
    st = %{st | assistant_delta?: false, started_tools: %{}}
    {:ok, {[%{type: :message_stop, stop_reason: "end_turn"}], st}}
  end

  defp turn_event_to_events(%Events.TurnFailed{} = ev, st, _model) do
    msg = Map.get(ev, :error) || Map.get(ev, :message) || inspect(ev)
    st = %{st | assistant_delta?: false, started_tools: %{}}
    {:ok, {[%{type: :error, error: msg}], st}}
  end

  defp turn_event_to_events(%Events.Error{message: message}, st, _model) do
    {:ok, {[%{type: :error, error: message}], st}}
  end

  defp turn_event_to_events(_event, _st, _model), do: :unhandled

  defp message_event_to_events(%Events.ItemAgentMessageDelta{item: item}, st, _model) do
    text = Map.get(item, "text") || Map.get(item, :text) || ""
    events = if is_binary(text) and text != "", do: [%{type: :text_delta, text: text}], else: []
    st = if events == [], do: st, else: %{st | assistant_delta?: true}
    {:ok, {events, st}}
  end

  defp message_event_to_events(%Events.ReasoningDelta{delta: delta}, st, _model) do
    if is_binary(delta) and delta != "" do
      {:ok, {[%{type: :thinking_delta, thinking: delta}], st}}
    else
      {:ok, {[], st}}
    end
  end

  defp message_event_to_events(%Events.ReasoningSummaryDelta{delta: delta}, st, _model) do
    if is_binary(delta) and delta != "" do
      {:ok, {[%{type: :thinking_delta, thinking: delta}], st}}
    else
      {:ok, {[], st}}
    end
  end

  defp message_event_to_events(_event, _st, _model), do: :unhandled

  defp item_event_to_events(%Events.ItemStarted{item: item}, st, _model) do
    {:ok, item_started_events(item, st)}
  end

  defp item_event_to_events(%Events.ItemCompleted{item: item}, st, _model) do
    {:ok, item_completed_events(item, st)}
  end

  defp item_event_to_events(%Events.ItemUpdated{}, st, _model), do: {:ok, {[], st}}
  defp item_event_to_events(%Events.CommandOutputDelta{}, st, _model), do: {:ok, {[], st}}
  defp item_event_to_events(_event, _st, _model), do: :unhandled

  defp tool_call_event_to_events(%Events.ToolCallRequested{} = ev, st, _model) do
    tool = Map.get(ev, :tool_name) || Map.get(ev, "tool_name") || "tool"
    id = Map.get(ev, :call_id) || Map.get(ev, "call_id") || unique_id(st)
    args = Map.get(ev, :arguments) || Map.get(ev, "arguments") || %{}
    json = safe_json(args)

    st = %{st | started_tools: Map.put(st.started_tools, id, tool), seq: st.seq + 1}

    events =
      [%{type: :tool_use_start, name: tool, id: id}] ++
        maybe_tool_input(json)

    {:ok, {events, st}}
  end

  defp tool_call_event_to_events(%Events.ToolCallCompleted{} = ev, st, _model) do
    tool = Map.get(ev, :tool_name) || Map.get(ev, "tool_name") || "tool"
    id = Map.get(ev, :call_id) || Map.get(ev, "call_id") || unique_id(st)

    result =
      Map.get(ev, :output) || Map.get(ev, "output") || Map.get(ev, :result) ||
        Map.get(ev, "result")

    st = %{st | started_tools: Map.delete(st.started_tools, id), seq: st.seq + 1}

    {:ok, {[%{type: :tool_complete, tool_name: tool, result: result}], st}}
  end

  defp tool_call_event_to_events(_event, _st, _model), do: :unhandled

  defp item_started_events(item, st) do
    case tool_from_item(item) do
      nil ->
        {[], st}

      %{tool_name: tool_name, tool_id: tool_id, input_json: input_json} ->
        st = %{st | started_tools: Map.put(st.started_tools, tool_id, tool_name)}

        events =
          [%{type: :tool_use_start, name: tool_name, id: tool_id}] ++
            maybe_tool_input(input_json)

        {events, st}
    end
  end

  defp item_completed_events(item, st) do
    case item_type(item) do
      :agent_message ->
        agent_message_events(item, st)

      _ ->
        tool_completion_events(item, st)
    end
  end

  defp agent_message_events(item, st) do
    if st.assistant_delta? do
      {[], st}
    else
      text = Map.get(item, :text) || Map.get(item, "text") || ""

      events =
        if is_binary(text) and String.trim(text) != "" do
          [%{type: :text_delta, text: text}]
        else
          []
        end

      {events, st}
    end
  end

  defp tool_completion_events(item, st) do
    case tool_from_item(item) do
      nil ->
        {[], st}

      %{tool_name: tool_name, tool_id: tool_id, result: result, input_json: input_json} ->
        {prefix, st} = ensure_tool_started(tool_id, tool_name, input_json, st)
        st = %{st | started_tools: Map.delete(st.started_tools, tool_id)}

        events =
          prefix ++
            [%{type: :tool_complete, tool_name: tool_name, result: result}]

        {events, st}
    end
  end

  defp ensure_tool_started(tool_id, tool_name, input_json, st) do
    if Map.has_key?(st.started_tools, tool_id) do
      {[], st}
    else
      st = %{st | started_tools: Map.put(st.started_tools, tool_id, tool_name)}

      prefix =
        [%{type: :tool_use_start, name: tool_name, id: tool_id}] ++
          maybe_tool_input(input_json)

      {prefix, st}
    end
  end

  defp maybe_tool_input(input_json) do
    if input_json == "" do
      []
    else
      [%{type: :tool_input_delta, json: input_json}]
    end
  end

  defp item_type(%Items.AgentMessage{}), do: :agent_message
  defp item_type(%Items.CommandExecution{}), do: :command_execution
  defp item_type(%Items.FileChange{}), do: :file_change
  defp item_type(%Items.McpToolCall{}), do: :mcp_tool_call

  defp item_type(item) when is_map(item) do
    Map.get(item, :type) || Map.get(item, "type")
  end

  defp tool_from_item(item) do
    case item_type(item) do
      :command_execution -> tool_from_command_execution(item)
      :file_change -> tool_from_file_change(item)
      :mcp_tool_call -> tool_from_mcp_tool_call(item)
      _ -> nil
    end
  end

  defp tool_from_command_execution(item) do
    id = fetch_value(item, [:id, "id"])
    cmd = fetch_value(item, [:command, "command"], "")
    tool_id = id || "cmd:" <> Integer.to_string(System.unique_integer([:positive]))
    input_json = safe_json(%{"command" => cmd})

    result = %{
      "command" => cmd,
      "status" => fetch_value(item, [:status, "status"]),
      "exit_code" => fetch_value(item, [:exit_code, "exit_code"]),
      "output" => fetch_value(item, [:aggregated_output, "aggregated_output"], "")
    }

    %{tool_name: "shell", tool_id: tool_id, input_json: input_json, result: result}
  end

  defp tool_from_file_change(item) do
    id = fetch_value(item, [:id, "id"])
    changes = fetch_value(item, [:changes, "changes"], [])
    tool_id = id || "fc:" <> Integer.to_string(System.unique_integer([:positive]))
    input_json = safe_json(%{"changes" => changes})

    result = %{
      "status" => fetch_value(item, [:status, "status"]),
      "changes" => changes
    }

    %{tool_name: "file_change", tool_id: tool_id, input_json: input_json, result: result}
  end

  defp tool_from_mcp_tool_call(item) do
    id = fetch_value(item, [:id, "id"])
    tool_id = id || "mcp:" <> Integer.to_string(System.unique_integer([:positive]))

    server = fetch_value(item, [:server, "server"])
    tool = fetch_value(item, [:tool, "tool"])
    args = fetch_value(item, [:arguments, "arguments"], %{})

    input_json = safe_json(%{"server" => server, "tool" => tool, "arguments" => args})

    result = %{
      "status" => fetch_value(item, [:status, "status"]),
      "server" => server,
      "tool" => tool,
      "arguments" => args,
      "result" => fetch_value(item, [:result, "result"]),
      "error" => fetch_value(item, [:error, "error"])
    }

    %{tool_name: "mcp", tool_id: tool_id, input_json: input_json, result: result}
  end

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end

  defp unique_id(st), do: "tool:" <> Integer.to_string(st.seq + 1)

  defp fetch_value(item, keys, default \\ nil) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(item, key) do
        nil -> nil
        value -> value
      end
    end)
  end
end
