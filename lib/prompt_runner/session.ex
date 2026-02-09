defmodule PromptRunner.Session do
  @moduledoc """
  Bridge between Prompt Runner and AgentSessionManager adapters.

  Starts the appropriate adapter (Claude, Codex, or Amp), runs a single prompt,
  normalizes the event stream into a common format, and provides a cleanup
  function for resource teardown.
  """

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error, as: ASMError
  alias AgentSessionManager.SessionManager
  alias PromptRunner.LLMFacade

  @stream_idle_timeout_ms 120_000
  @shutdown_timeout_ms 5_000
  @agent_id "prompt-runner"

  @type provider :: PromptRunner.LLM.provider()
  @type llm_config :: map()
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> :ok)

  @doc """
  Starts a streaming prompt session and returns a lazy event stream.
  """
  @spec start_stream(llm_config(), String.t()) ::
          {:ok, stream(), close_fun(), map()} | {:error, term()}
  def start_stream(llm_config, prompt) when is_map(llm_config) and is_binary(prompt) do
    with :ok <- ensure_runtime_started(),
         {:ok, provider} <- normalize_provider(llm_config),
         {:ok, store_pid} <- start_store() do
      case start_adapter(provider, llm_config) do
        {:ok, adapter_pid} ->
          build_stream_session(provider, llm_config, prompt, store_pid, adapter_pid)

        {:error, reason} ->
          cleanup_children([store_pid])
          {:error, reason}
      end
    end
  end

  defp build_stream_session(provider, llm_config, prompt, store_pid, adapter_pid) do
    stream_ref = make_ref()
    parent = self()

    task_fun = fn ->
      result = run_once(store_pid, adapter_pid, prompt, parent, stream_ref)
      send(parent, {stream_ref, :done, result})
    end

    case Task.Supervisor.start_child(PromptRunner.TaskSupervisor, task_fun) do
      {:ok, task_pid} ->
        task_monitor = Process.monitor(task_pid)

        stream = build_event_stream(stream_ref, task_pid, task_monitor)

        close_fun = fn ->
          stop_task(task_pid)
          cleanup_children([adapter_pid, store_pid])
          Process.demonitor(task_monitor, [:flush])
          :ok
        end

        meta = %{
          sdk: provider,
          model: llm_config[:model],
          cwd: llm_config[:cwd]
        }

        {:ok, stream, close_fun, meta}

      {:error, reason} ->
        cleanup_children([adapter_pid, store_pid])
        {:error, reason}
    end
  end

  defp build_event_stream(stream_ref, task_pid, task_monitor) do
    Stream.resource(
      fn -> :running end,
      fn
        :done ->
          {:halt, :done}

        :running ->
          next_stream_events(stream_ref, task_pid, task_monitor)
      end,
      fn _state -> :ok end
    )
  end

  defp next_stream_events(stream_ref, task_pid, task_monitor) do
    receive do
      {^stream_ref, :event, event} ->
        {normalize_event_list(event), :running}

      {^stream_ref, :done, {:ok, _result}} ->
        {:halt, :done}

      {^stream_ref, :done, {:error, reason}} ->
        {done_error_events(reason), :done}

      {:DOWN, ^task_monitor, :process, ^task_pid, :normal} ->
        {:halt, :done}

      {:DOWN, ^task_monitor, :process, ^task_pid, reason} ->
        {done_error_events({:task_down, reason}), :done}
    after
      @stream_idle_timeout_ms ->
        {
          [
            %{
              type: :error,
              error: "stream timeout after #{@stream_idle_timeout_ms}ms"
            }
          ],
          :done
        }
    end
  end

  defp normalize_event_list(event) do
    case normalize_event(event) do
      nil -> []
      events when is_list(events) -> events
      single -> [single]
    end
  end

  defp done_error_events(%ASMError{} = error) do
    [
      %{
        type: :error,
        error_type: error.code,
        error: error.message
      }
    ]
  end

  defp done_error_events({:task_down, :shutdown}) do
    [%{type: :error, error: "session task shutdown"}]
  end

  defp done_error_events({:task_down, :killed}) do
    [%{type: :error, error: "session task killed"}]
  end

  defp done_error_events({:task_down, reason}) do
    [%{type: :error, error: "session task crashed: #{inspect(reason)}"}]
  end

  defp done_error_events({:exception, exception, stacktrace}) do
    [
      %{
        type: :error,
        error: Exception.format(:error, exception, stacktrace)
      }
    ]
  end

  defp done_error_events({kind, reason}) when kind in [:throw, :exit] do
    [%{type: :error, error: "session terminated (#{kind}): #{inspect(reason)}"}]
  end

  defp done_error_events(reason) do
    [%{type: :error, error: inspect(reason)}]
  end

  defp run_once(store_pid, adapter_pid, prompt, parent, stream_ref) do
    event_callback = fn event -> send(parent, {stream_ref, :event, event}) end

    SessionManager.run_once(
      store_pid,
      adapter_pid,
      %{messages: [%{role: "user", content: prompt}]},
      event_callback: event_callback,
      agent_id: @agent_id
    )
  rescue
    exception ->
      {:error, {:exception, exception, __STACKTRACE__}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp start_store do
    start_supervised_child({InMemorySessionStore, []})
  end

  defp start_adapter(:claude, llm_config) do
    opts =
      []
      |> maybe_put(:model, resolve_claude_model(llm_config[:model]))
      |> maybe_put(:cwd, llm_config[:cwd])
      |> maybe_put(:tools, llm_config[:allowed_tools])
      |> maybe_put(:permission_mode, llm_config[:permission_mode])
      |> maybe_put(:max_turns, llm_config[:max_turns])
      |> maybe_put(:system_prompt, llm_config[:system_prompt])
      |> maybe_put(:sdk_opts, llm_config[:sdk_opts])
      |> Keyword.merge(normalize_opts(llm_config[:claude_opts]))
      |> Keyword.merge(normalize_opts(llm_config[:adapter_opts]))

    start_supervised_child({ClaudeAdapter, opts})
  end

  defp start_adapter(:codex, llm_config) do
    with {:ok, cwd} <- require_cwd(llm_config, :codex) do
      codex_sdk_opts =
        llm_config[:sdk_opts]
        |> normalize_opts()
        |> Keyword.merge(normalize_opts(llm_config[:codex_opts]))
        |> Keyword.merge(normalize_opts(llm_config[:codex_thread_opts]))

      opts =
        []
        |> maybe_put(:model, llm_config[:model])
        |> maybe_put(:working_directory, cwd)
        |> maybe_put(:permission_mode, llm_config[:permission_mode])
        |> maybe_put(:max_turns, llm_config[:max_turns])
        |> maybe_put(:system_prompt, llm_config[:system_prompt])
        |> maybe_put(:sdk_opts, codex_sdk_opts)
        |> Keyword.merge(normalize_opts(llm_config[:adapter_opts]))
        |> ensure_option(:working_directory, cwd)

      start_supervised_child({CodexAdapter, opts})
    end
  end

  defp start_adapter(:amp, llm_config) do
    with {:ok, cwd} <- require_cwd(llm_config, :amp) do
      opts =
        []
        |> maybe_put(:cwd, cwd)
        |> maybe_put(:permission_mode, llm_config[:permission_mode])
        |> maybe_put(:max_turns, llm_config[:max_turns])
        |> maybe_put(:system_prompt, llm_config[:system_prompt])
        |> maybe_put(:sdk_opts, llm_config[:sdk_opts])
        |> Keyword.merge(normalize_opts(llm_config[:adapter_opts]))
        |> ensure_option(:cwd, cwd)

      start_supervised_child({AmpAdapter, opts})
    end
  end

  defp normalize_event(%{type: :run_started, data: data}) do
    %{
      type: :message_start,
      model: get_data(data, :model),
      role: "assistant",
      session_id: get_data(data, :session_id)
    }
  end

  defp normalize_event(%{type: :message_streamed, data: data}) do
    %{
      type: :text_delta,
      text: get_data(data, :delta) || get_data(data, :content) || ""
    }
  end

  defp normalize_event(%{type: :tool_call_started, data: data}) do
    base_event = %{
      type: :tool_use_start,
      name: get_data(data, :tool_name),
      id: get_data(data, :tool_call_id) || get_data(data, :tool_use_id)
    }

    case tool_input_delta(data) do
      nil -> base_event
      input_delta -> [base_event, input_delta]
    end
  end

  defp normalize_event(%{type: :tool_call_completed, data: data}) do
    %{
      type: :tool_complete,
      tool_name: get_data(data, :tool_name),
      result: get_data(data, :tool_output)
    }
  end

  defp normalize_event(%{type: :token_usage_updated, data: data}) do
    %{
      type: :message_delta,
      stop_reason: nil,
      stop_sequence: nil,
      usage: %{
        input_tokens: get_data(data, :input_tokens),
        output_tokens: get_data(data, :output_tokens)
      }
    }
  end

  defp normalize_event(%{type: :run_completed, data: data}) do
    %{
      type: :message_stop,
      stop_reason: get_data(data, :stop_reason) || "end_turn"
    }
  end

  defp normalize_event(%{type: :run_failed, data: data}) do
    %{
      type: :error,
      error_type: get_data(data, :error_code),
      error: get_data(data, :error_message) || "execution failed"
    }
  end

  defp normalize_event(%{type: :run_cancelled}) do
    %{type: :error, error: "cancelled"}
  end

  defp normalize_event(%{type: :error_occurred, data: data}) do
    %{
      type: :error,
      error_type: get_data(data, :error_code),
      error: get_data(data, :error_message) || "error occurred"
    }
  end

  defp normalize_event(%{type: :message_received}) do
    nil
  end

  defp normalize_event(%{type: type, data: data}) do
    %{type: type, data: data}
  end

  defp normalize_event(event), do: event

  defp tool_input_delta(data) do
    case get_data(data, :tool_input) do
      nil ->
        nil

      input when is_map(input) and map_size(input) == 0 ->
        nil

      input ->
        case Jason.encode(input) do
          {:ok, json} -> %{type: :tool_input_delta, json: json}
          _ -> %{type: :tool_input_delta, input: inspect(input)}
        end
    end
  end

  defp get_data(data, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp get_data(_data, _key), do: nil

  defp require_cwd(llm_config, provider) do
    cwd = llm_config[:cwd]

    if is_binary(cwd) and cwd != "" do
      {:ok, cwd}
    else
      {:error, {:missing_cwd, provider}}
    end
  end

  defp normalize_provider(llm_config) do
    candidate = llm_config[:provider] || llm_config[:sdk]

    case LLMFacade.normalize_provider(candidate) do
      provider when provider in [:claude, :codex, :amp] -> {:ok, provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_runtime_started do
    case Application.ensure_all_started(:prompt_runner_sdk) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:runtime_not_started, reason}}
    end
  end

  defp start_supervised_child({module, opts}) do
    case DynamicSupervisor.start_child(PromptRunner.SessionSupervisor, {module, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_task(task_pid) when is_pid(task_pid) do
    Process.exit(task_pid, :shutdown)
    await_task_exit(task_pid)
    :ok
  end

  defp await_task_exit(task_pid) do
    monitor = Process.monitor(task_pid)

    receive do
      {:DOWN, ^monitor, :process, ^task_pid, _reason} ->
        :ok
    after
      @shutdown_timeout_ms ->
        Process.exit(task_pid, :kill)
        :ok
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp cleanup_children(pids) do
    Enum.each(pids, &terminate_child/1)
    :ok
  end

  defp terminate_child(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(PromptRunner.SessionSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp terminate_child(_other), do: :ok

  defp resolve_claude_model(nil), do: nil
  defp resolve_claude_model("haiku"), do: "claude-haiku-4-5-20251001"
  defp resolve_claude_model("sonnet"), do: "claude-sonnet-4-5-20250929"
  defp resolve_claude_model("opus"), do: "claude-opus-4-6"
  defp resolve_claude_model(model), do: model

  defp normalize_opts(nil), do: []
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.into(opts, [])
  defp normalize_opts(_opts), do: []

  defp ensure_option(opts, key, value) do
    if Keyword.get(opts, key) in [nil, ""] do
      Keyword.put(opts, key, value)
    else
      opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
