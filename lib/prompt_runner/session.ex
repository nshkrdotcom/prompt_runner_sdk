defmodule PromptRunner.Session do
  @moduledoc """
  Prompt Runner bridge onto the current ASM session runtime.

  This module starts provider sessions through `ASM`, projects wrapped
  `CliSubprocessCore` events into Prompt Runner's canonical event vocabulary,
  and preserves provider-native recovery handles so the runner can attempt an
  exact session resume instead of replaying the full prompt from scratch.
  """

  alias CliSubprocessCore.Payload
  alias PromptRunner.LLMFacade

  @agent_id "prompt-runner"
  @default_stream_idle_timeout 120_000
  @stream_idle_timeout_buffer 30_000
  @emergency_timeout_ms 7 * 86_400_000

  @type provider :: PromptRunner.LLM.provider()
  @type llm_config :: map()
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> :ok)

  @common_provider_option_keys [
    :cli_path,
    :env,
    :args,
    :debug,
    :ollama,
    :ollama_model,
    :ollama_base_url,
    :ollama_http,
    :ollama_timeout_ms
  ]
  @claude_provider_option_keys [
    :model,
    :system_prompt,
    :provider_backend,
    :external_model_overrides,
    :anthropic_base_url,
    :anthropic_auth_token,
    :include_thinking,
    :max_turns,
    :append_system_prompt
  ]
  @codex_provider_option_keys [
    :model,
    :system_prompt,
    :reasoning_effort,
    :provider_backend,
    :model_provider,
    :oss_provider,
    :skip_git_repo_check,
    :output_schema,
    :additional_directories
  ]
  @gemini_provider_option_keys [
    :model,
    :system_prompt,
    :sandbox,
    :extensions
  ]
  @amp_provider_option_keys [
    :model,
    :mode,
    :include_thinking,
    :max_turns,
    :permissions,
    :mcp_config,
    :tools
  ]

  @doc """
  Starts a streaming prompt session and returns a lazy event stream.
  """
  @spec start_stream(llm_config(), String.t()) ::
          {:ok, stream(), close_fun(), map()} | {:error, term()}
  def start_stream(llm_config, prompt) when is_map(llm_config) and is_binary(prompt) do
    with {:ok, provider} <- normalize_provider(llm_config),
         {:ok, session_opts, stream_opts} <- build_asm_options(provider, llm_config),
         {:ok, session} <- ASM.start_session(session_opts),
         {:ok, state_ref} <- start_state_ref(provider, llm_config, session, session_opts) do
      stream = build_stream(session, prompt, stream_opts, provider, state_ref)

      meta =
        build_meta(provider, llm_config, session, session_opts, stream_opts, state_ref)

      {:ok, stream, close_fun(session, state_ref), meta}
    end
  end

  @doc """
  Resumes an existing provider-native conversation with a continuation prompt.
  """
  @spec resume_stream(llm_config(), map(), String.t()) ::
          {:ok, stream(), close_fun(), map()} | {:error, term()}
  def resume_stream(llm_config, meta, prompt)
      when is_map(llm_config) and is_map(meta) and is_binary(prompt) do
    with {:ok, provider} <- normalize_provider(llm_config),
         {:ok, continuation} <- build_resume_continuation(meta),
         {:ok, session_opts, stream_opts} <- build_asm_options(provider, llm_config),
         {:ok, session, state_ref} <- ensure_resume_session(provider, meta, session_opts),
         stream_opts <- Keyword.put(stream_opts, :continuation, continuation) do
      stream = build_stream(session, prompt, stream_opts, provider, state_ref)

      next_meta =
        build_meta(provider, llm_config, session, session_opts, stream_opts, state_ref)
        |> Map.put(:recovery_attempt?, true)
        |> Map.put(:continuation, continuation)

      {:ok, stream, close_fun(session, state_ref), next_meta}
    end
  end

  @doc false
  @spec effective_timeout_ms_for_config(llm_config()) :: pos_integer()
  def effective_timeout_ms_for_config(llm_config) when is_map(llm_config) do
    resolve_effective_timeout_ms(llm_config)
  end

  @doc false
  @spec resolve_stream_idle_timeout_for_config(llm_config()) :: pos_integer()
  def resolve_stream_idle_timeout_for_config(llm_config) when is_map(llm_config) do
    resolve_stream_idle_timeout(llm_config)
  end

  @doc false
  @spec build_run_opts_for_config(llm_config()) :: keyword()
  def build_run_opts_for_config(llm_config) when is_map(llm_config) do
    build_run_opts(llm_config)
  end

  defp build_stream(session, prompt, stream_opts, provider, state_ref) do
    session
    |> ASM.stream(prompt, stream_opts)
    |> Stream.flat_map(fn event ->
      capture_event_state(state_ref, event)
      bridge_event(event, provider)
    end)
  end

  defp ensure_resume_session(provider, meta, session_opts) do
    state_ref =
      Map.get(meta, :state_ref) ||
        Map.get(meta, "state_ref")

    session =
      Map.get(meta, :session) ||
        Map.get(meta, "session")

    cond do
      is_pid(session) and Process.alive?(session) and is_pid(state_ref) ->
        update_state_ref(state_ref, %{
          session: session,
          provider: provider,
          session_opts: session_opts
        })

        {:ok, session, state_ref}

      is_pid(state_ref) ->
        with {:ok, session} <- ASM.start_session(session_opts) do
          update_state_ref(state_ref, %{
            session: session,
            provider: provider,
            session_opts: session_opts
          })

          {:ok, session, state_ref}
        end

      true ->
        with {:ok, session} <- ASM.start_session(session_opts),
             {:ok, state_ref} <- start_state_ref(provider, %{}, session, session_opts) do
          {:ok, session, state_ref}
        end
    end
  end

  defp build_meta(provider, llm_config, session, session_opts, stream_opts, state_ref) do
    %{
      sdk: provider,
      provider: provider,
      model: llm_config[:model],
      cwd: llm_config[:cwd],
      session: session,
      session_id: ASM.session_id(session),
      session_opts: session_opts,
      stream_opts: stream_opts,
      state_ref: state_ref
    }
  end

  defp start_state_ref(provider, llm_config, session, session_opts) do
    state =
      %{
        provider: provider,
        session: session,
        session_id: ASM.session_id(session),
        session_opts: session_opts,
        provider_session_id: nil,
        last_run_id: nil,
        checkpoint: nil,
        last_error: nil,
        llm: %{
          sdk: provider,
          model: llm_config[:model],
          cwd: llm_config[:cwd]
        }
      }

    Agent.start_link(fn -> state end)
  end

  defp close_fun(session, state_ref) do
    fn ->
      safe_stop_session(session)
      safe_stop_state_ref(state_ref)
      :ok
    end
  end

  defp safe_stop_session(session) when is_pid(session) do
    _ = ASM.stop_session(session)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp safe_stop_session(_session), do: :ok

  defp safe_stop_state_ref(state_ref) when is_pid(state_ref) do
    Agent.stop(state_ref, :normal)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp build_resume_continuation(meta) do
    state_ref = meta_value(meta, :state_ref)
    session = meta_value(meta, :session)
    checkpoint = resume_checkpoint(session, state_ref)

    case ASM.SessionControl.continuation_from_checkpoint(checkpoint, target: :checkpoint) do
      {:ok, continuation} ->
        maybe_cache_checkpoint(state_ref, checkpoint)
        {:ok, continuation}

      {:error, _error} ->
        continuation_from_cached_provider_session(state_ref)
    end
  end

  defp meta_value(meta, key) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  end

  defp resume_checkpoint(session, state_ref) do
    cond do
      is_pid(session) and Process.alive?(session) ->
        case ASM.checkpoint(session) do
          {:ok, value} -> value
          _other -> nil
        end

      is_pid(state_ref) ->
        Agent.get(state_ref, &Map.get(&1, :checkpoint))

      true ->
        nil
    end
  end

  defp continuation_from_cached_provider_session(state_ref) do
    with {:ok, provider_session_id} <- cached_provider_session_id(state_ref) do
      {:ok, %{strategy: :exact, provider_session_id: provider_session_id}}
    end
  end

  defp maybe_cache_checkpoint(state_ref, checkpoint)
       when is_pid(state_ref) and is_map(checkpoint) do
    update_state_ref(state_ref, %{checkpoint: checkpoint})
  end

  defp maybe_cache_checkpoint(_state_ref, _checkpoint), do: :ok

  defp cached_provider_session_id(state_ref) when is_pid(state_ref) do
    provider_session_id =
      Agent.get(state_ref, fn state ->
        state[:provider_session_id] ||
          state[:checkpoint][:provider_session_id]
      end)

    if is_binary(provider_session_id) and provider_session_id != "" do
      {:ok, provider_session_id}
    else
      {:error, :missing_provider_session_id}
    end
  catch
    :exit, _reason ->
      {:error, :missing_provider_session_id}
  end

  defp cached_provider_session_id(_state_ref), do: {:error, :missing_provider_session_id}

  defp update_state_ref(state_ref, attrs) when is_pid(state_ref) and is_map(attrs) do
    Agent.update(state_ref, &Map.merge(&1, attrs))
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp capture_event_state(state_ref, %{session_id: session_id, run_id: run_id} = event)
       when is_pid(state_ref) do
    provider_session_id =
      event_provider_session_id(event) ||
        raw_thread_id(event)

    checkpoint =
      if is_binary(provider_session_id) and provider_session_id != "" do
        %{
          provider_session_id: provider_session_id,
          metadata: %{source: checkpoint_source(event)}
        }
      end

    attrs =
      %{
        session_id: session_id,
        last_run_id: run_id,
        provider_session_id:
          provider_session_id || current_state_value(state_ref, :provider_session_id),
        checkpoint: checkpoint || current_state_value(state_ref, :checkpoint),
        last_error: last_error_from_event(event)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    update_state_ref(state_ref, attrs)
  end

  defp capture_event_state(_state_ref, _event), do: :ok

  defp current_state_value(state_ref, key) when is_pid(state_ref) do
    Agent.get(state_ref, &Map.get(&1, key))
  catch
    :exit, _reason ->
      nil
  end

  defp event_provider_session_id(%{provider_session_id: provider_session_id})
       when is_binary(provider_session_id) and provider_session_id != "",
       do: provider_session_id

  defp event_provider_session_id(%{metadata: metadata}) when is_map(metadata) do
    metadata[:provider_session_id] ||
      metadata["provider_session_id"]
  end

  defp event_provider_session_id(_event), do: nil

  defp raw_thread_id(%{
         core_event: %{raw: %{"type" => "thread.started", "thread_id" => thread_id}}
       })
       when is_binary(thread_id) and thread_id != "",
       do: thread_id

  defp raw_thread_id(%{
         core_event: %{raw: %{type: "thread.started", thread_id: thread_id}}
       })
       when is_binary(thread_id) and thread_id != "",
       do: thread_id

  defp raw_thread_id(_event), do: nil

  defp checkpoint_source(%{kind: :run_started}), do: "run_started"
  defp checkpoint_source(%{kind: :raw}), do: "raw.thread_started"
  defp checkpoint_source(_event), do: "event"

  defp last_error_from_event(%{kind: :error} = event), do: provider_error_from_event(event)
  defp last_error_from_event(_event), do: nil

  defp bridge_event(
         %{kind: :assistant_delta, payload: %Payload.AssistantDelta{} = payload} = event,
         _provider
       ) do
    [
      legacy_event(event, :message_streamed, %{
        content: payload.content,
        delta: payload.content
      })
    ]
  end

  defp bridge_event(
         %{kind: :assistant_message, payload: %Payload.AssistantMessage{} = payload} = event,
         _provider
       ) do
    [
      legacy_event(event, :message_received, %{
        content: extract_text(payload.content),
        role: "assistant"
      })
    ]
  end

  defp bridge_event(
         %{kind: :user_message, payload: %Payload.UserMessage{} = payload} = event,
         _provider
       ) do
    [
      legacy_event(event, :message_sent, %{
        content: extract_text(payload.content),
        role: "user"
      })
    ]
  end

  defp bridge_event(%{kind: :thinking, payload: %Payload.Thinking{} = payload} = event, _provider) do
    [
      legacy_event(event, :message_streamed, %{
        content: payload.content,
        delta: payload.content,
        kind: :thinking
      })
    ]
  end

  defp bridge_event(%{kind: :tool_use, payload: %Payload.ToolUse{} = payload} = event, _provider) do
    [
      legacy_event(event, :tool_call_started, %{
        tool_call_id: payload.tool_call_id,
        tool_name: payload.tool_name,
        tool_input: payload.input
      })
    ]
  end

  defp bridge_event(
         %{kind: :tool_result, payload: %Payload.ToolResult{} = payload} = event,
         _provider
       ) do
    type = if payload.is_error, do: :tool_call_failed, else: :tool_call_completed

    [
      legacy_event(event, type, %{
        tool_call_id: payload.tool_call_id,
        tool_output: payload.content,
        is_error: payload.is_error
      })
    ]
  end

  defp bridge_event(
         %{kind: :approval_requested, payload: %Payload.ApprovalRequested{} = payload} = event,
         _provider
       ) do
    [
      legacy_event(event, :tool_approval_requested, %{
        approval_id: payload.approval_id,
        tool_name: payload.subject,
        tool_input: payload.details
      })
    ]
  end

  defp bridge_event(
         %{kind: :approval_resolved, payload: %Payload.ApprovalResolved{} = payload} = event,
         _provider
       ) do
    type = if payload.decision == :allow, do: :tool_approval_granted, else: :tool_approval_denied

    [
      legacy_event(event, type, %{
        approval_id: payload.approval_id,
        decision: payload.decision,
        reason: payload.reason
      })
    ]
  end

  defp bridge_event(
         %{kind: :cost_update, payload: %Payload.CostUpdate{} = payload} = event,
         _provider
       ) do
    [
      legacy_event(event, :token_usage_updated, %{
        input_tokens: payload.input_tokens,
        output_tokens: payload.output_tokens,
        cost_usd: payload.cost_usd
      })
    ]
  end

  defp bridge_event(
         %{kind: :run_started, payload: %Payload.RunStarted{} = payload} = event,
         provider
       ) do
    [legacy_event(event, :run_started, run_started_data(payload, provider))]
  end

  defp bridge_event(%{kind: :result, payload: %Payload.Result{} = payload} = event, _provider) do
    usage = usage_map(payload.output)

    [
      legacy_event(event, :token_usage_updated, usage),
      legacy_event(event, :run_completed, %{
        stop_reason: payload.stop_reason,
        duration_ms: nil,
        token_usage: usage,
        metadata: normalize_map(payload.metadata)
      })
    ]
  end

  defp bridge_event(%{kind: :error, payload: %Payload.Error{} = payload} = event, _provider) do
    provider_error = provider_error_from_event(event)

    error_data = %{
      error_code: payload.code,
      error_message: payload.message,
      severity: payload.severity,
      provider_error: provider_error,
      details: normalize_map(payload.metadata)
    }

    [
      legacy_event(event, :error_occurred, error_data),
      legacy_event(event, :run_failed, Map.drop(error_data, [:severity]))
    ]
  end

  defp bridge_event(%{kind: :raw} = event, :codex) do
    case codex_hidden_confirmation_event(event) do
      nil -> []
      hidden -> [hidden]
    end
  end

  defp bridge_event(%{kind: :stderr}, _provider), do: []
  defp bridge_event(_event, _provider), do: []

  defp codex_hidden_confirmation_event(
         %{
           core_event: %{raw: %{"type" => "thread.started"} = raw},
           provider: provider
         } = event
       ) do
    metadata = Map.get(raw, "metadata", %{})
    thread_id = Map.get(raw, "thread_id")
    model = Map.get(metadata, "model")

    reasoning_effort =
      Map.get(metadata, "reasoning_effort") || Map.get(metadata, "reasoningEffort")

    legacy_event(
      event,
      :run_started,
      %{
        provider_session_id: thread_id,
        model: model,
        confirmed_model: model,
        reasoning_effort: reasoning_effort,
        confirmed_reasoning_effort: stringify_or_nil(reasoning_effort),
        metadata: metadata,
        confirmation_source: "codex.thread.started"
      },
      %{provider: provider, hidden?: true}
    )
  end

  defp codex_hidden_confirmation_event(
         %{
           core_event: %{raw: %{type: "thread.started"} = raw},
           provider: provider
         } = event
       ) do
    metadata = Map.get(raw, :metadata, %{})
    thread_id = Map.get(raw, :thread_id)
    model = Map.get(metadata, :model)
    reasoning_effort = Map.get(metadata, :reasoning_effort) || Map.get(metadata, :reasoningEffort)

    legacy_event(
      event,
      :run_started,
      %{
        provider_session_id: thread_id,
        model: model,
        confirmed_model: model,
        reasoning_effort: reasoning_effort,
        confirmed_reasoning_effort: stringify_or_nil(reasoning_effort),
        metadata: metadata,
        confirmation_source: "codex.thread.started"
      },
      %{provider: provider, hidden?: true}
    )
  end

  defp codex_hidden_confirmation_event(_event), do: nil

  defp run_started_data(%Payload.RunStarted{} = payload, :codex) do
    metadata = normalize_map(payload.metadata)

    %{
      provider_session_id: payload.provider_session_id,
      command: payload.command,
      args: payload.args,
      cwd: payload.cwd,
      metadata: metadata,
      model: metadata[:model] || metadata["model"],
      confirmed_model: metadata[:model] || metadata["model"],
      reasoning_effort:
        metadata[:reasoning_effort] ||
          metadata["reasoning_effort"] ||
          metadata[:reasoningEffort] ||
          metadata["reasoningEffort"],
      confirmed_reasoning_effort:
        stringify_or_nil(
          metadata[:reasoning_effort] ||
            metadata["reasoning_effort"] ||
            metadata[:reasoningEffort] ||
            metadata["reasoningEffort"]
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp run_started_data(%Payload.RunStarted{} = payload, _provider) do
    %{
      provider_session_id: payload.provider_session_id,
      command: payload.command,
      args: payload.args,
      cwd: payload.cwd,
      metadata: normalize_map(payload.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp legacy_event(event, type, data, extra \\ %{}) do
    %{
      type: type,
      timestamp: event.timestamp,
      session_id: event.session_id,
      run_id: event.run_id,
      provider: Map.get(extra, :provider, event.provider),
      data: normalize_map(data)
    }
    |> maybe_put_root(:hidden?, Map.get(extra, :hidden?))
  end

  defp provider_error_from_event(
         %{payload: %Payload.Error{} = payload, provider: provider} = event
       ) do
    runtime_failure = runtime_failure_metadata(payload.metadata)
    context = normalize_map(runtime_failure[:context] || runtime_failure["context"])
    message = payload.message

    %{
      provider: provider,
      kind: normalize_error_kind(payload.code, message, runtime_failure),
      message: message,
      exit_code: runtime_failure[:exit_code] || runtime_failure["exit_code"],
      stderr: runtime_failure[:stderr] || runtime_failure["stderr"],
      truncated?:
        truthy?(
          runtime_failure[:stderr_truncated?] ||
            runtime_failure["stderr_truncated?"] ||
            runtime_failure[:stderr_truncated] ||
            runtime_failure["stderr_truncated"]
        ),
      retryable?:
        recoverable_error_kind?(normalize_error_kind(payload.code, message, runtime_failure)),
      provider_session_id: event.provider_session_id || raw_thread_id(event),
      context: context
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp runtime_failure_metadata(metadata) when is_map(metadata) do
    metadata[:runtime_failure] ||
      metadata["runtime_failure"] ||
      %{}
  end

  defp runtime_failure_metadata(_metadata), do: %{}

  defp normalize_error_kind(code, message, runtime_failure) do
    candidate = error_kind_candidate(code, runtime_failure)
    message_text = normalized_error_message(message)

    cond do
      protocol_error_message?(message_text) ->
        :protocol_error

      known_error_kind(candidate) != nil ->
        known_error_kind(candidate)

      is_binary(candidate) and candidate != "" ->
        normalize_error_kind_candidate(candidate)

      true ->
        :unknown
    end
  end

  defp error_kind_candidate(code, runtime_failure) do
    runtime_kind =
      runtime_failure[:kind] ||
        runtime_failure["kind"]

    case runtime_kind do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> code
    end
  end

  defp normalized_error_message(message) when is_binary(message), do: String.downcase(message)
  defp normalized_error_message(_message), do: ""

  defp protocol_error_message?(message_text) do
    String.contains?(message_text, "websocket protocol error") or
      String.contains?(message_text, "protocol error") or
      String.contains?(message_text, "connection reset without closing handshake")
  end

  defp known_error_kind("transport_exit"), do: :transport_exit
  defp known_error_kind("buffer_overflow"), do: :buffer_overflow
  defp known_error_kind("auth_error"), do: :auth_error
  defp known_error_kind("cli_not_found"), do: :cli_not_found
  defp known_error_kind("config_invalid"), do: :config_invalid
  defp known_error_kind("transport_error"), do: :transport_error
  defp known_error_kind(_candidate), do: nil

  defp normalize_error_kind_candidate(candidate) do
    candidate
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp recoverable_error_kind?(kind)
       when kind in [:protocol_error, :transport_error, :transport_exit],
       do: true

  defp recoverable_error_kind?(_kind), do: false

  defp usage_map(output) when is_map(output) do
    usage =
      output[:usage] ||
        output["usage"] ||
        %{}

    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
      output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
      total_tokens: usage[:total_tokens] || usage["total_tokens"] || 0
    }
  end

  defp usage_map(_output) do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map_join("", fn
      value when is_binary(value) ->
        value

      %{} = block ->
        block[:text] || block["text"] || block[:content] || block["content"] || ""

      other ->
        to_string(other)
    end)
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_blocks), do: ""

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value) when is_binary(value), do: value
  defp stringify_or_nil(value), do: to_string(value)

  defp maybe_put_root(map, _key, nil), do: map
  defp maybe_put_root(map, key, value), do: Map.put(map, key, value)

  # -- ASM option builders

  defp build_asm_options(provider, llm_config) do
    with {:ok, provider_opts} <- provider_opts(provider, llm_config) do
      common_opts =
        []
        |> Keyword.put(:provider, provider)
        |> maybe_put(:cwd, llm_config[:cwd])
        |> maybe_put(:permission_mode, llm_config[:permission_mode])
        |> maybe_put(:allowed_tools, llm_config[:allowed_tools])
        |> maybe_put(:transport_timeout_ms, resolve_effective_timeout_ms(llm_config))
        |> maybe_put(:max_stdout_buffer_bytes, resolve_max_stdout_buffer_bytes(llm_config))
        |> maybe_put(:max_stderr_buffer_bytes, resolve_max_stderr_buffer_bytes(llm_config))
        |> maybe_put(:metadata, session_metadata(llm_config))

      stream_opts =
        []
        |> maybe_put(:stream_timeout_ms, resolve_effective_timeout_ms(llm_config))
        |> maybe_put(:queue_timeout_ms, resolve_stream_idle_timeout(llm_config))
        |> maybe_put(:continuation, normalize_continuation(llm_config[:continuation]))

      {:ok, common_opts ++ provider_opts, stream_opts}
    end
  end

  defp provider_opts(:claude, llm_config) do
    provider_opts_from_sections(
      llm_config,
      @claude_provider_option_keys,
      []
      |> maybe_put(:model, resolve_claude_model(llm_config[:model]))
      |> maybe_put(:max_turns, llm_config[:max_turns])
      |> maybe_put(:system_prompt, llm_config[:system_prompt])
      |> maybe_put(:append_system_prompt, llm_config[:append_system_prompt])
    )
  end

  defp provider_opts(:codex, llm_config) do
    with {:ok, cwd} <- require_cwd(llm_config, :codex),
         {:ok, provider_opts} <-
           provider_opts_from_sections(
             llm_config,
             @codex_provider_option_keys,
             []
             |> maybe_put(:model, llm_config[:model])
             |> maybe_put(:system_prompt, llm_config[:system_prompt])
             |> maybe_put(:cwd, cwd)
             |> maybe_put(:additional_directories, codex_additional_directories(llm_config))
           ) do
      {:ok, Keyword.put(provider_opts, :cwd, cwd)}
    end
  end

  defp provider_opts(:gemini, llm_config) do
    with {:ok, cwd} <- require_cwd(llm_config, :gemini) do
      provider_opts_from_sections(
        llm_config,
        @gemini_provider_option_keys,
        []
        |> maybe_put(:model, llm_config[:model])
        |> maybe_put(:system_prompt, llm_config[:system_prompt])
        |> maybe_put(:cwd, cwd)
      )
    end
  end

  defp provider_opts(:amp, llm_config) do
    with {:ok, cwd} <- require_cwd(llm_config, :amp) do
      provider_opts_from_sections(
        llm_config,
        @amp_provider_option_keys,
        []
        |> maybe_put(:model, llm_config[:model])
        |> maybe_put(:max_turns, llm_config[:max_turns])
        |> maybe_put(:cwd, cwd)
      )
    end
  end

  defp provider_opts_from_sections(llm_config, provider_keys, base_opts) do
    allowed_keys = Enum.uniq(@common_provider_option_keys ++ provider_keys)

    merged =
      llm_config
      |> provider_option_sections()
      |> Enum.reduce(%{}, &Map.merge(&2, &1))

    unknown_keys =
      merged
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))

    case unknown_keys do
      [] ->
        section_opts =
          merged
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Keyword.new()

        {:ok, Keyword.merge(base_opts, section_opts)}

      [unknown | _rest] ->
        {:error, {:unsupported_provider_option, unknown}}
    end
  end

  defp provider_option_sections(llm_config) do
    provider_specific =
      case normalize_provider(llm_config) do
        {:ok, :claude} -> [llm_config[:claude_opts]]
        {:ok, :codex} -> [llm_config[:codex_opts], llm_config[:codex_thread_opts]]
        {:ok, :gemini} -> [llm_config[:gemini_opts]]
        {:ok, :amp} -> [llm_config[:amp_opts]]
        _ -> []
      end

    [llm_config[:sdk_opts], llm_config[:adapter_opts] | provider_specific]
    |> Enum.map(&normalize_opts_map/1)
  end

  defp normalize_opts_map(nil), do: %{}

  defp normalize_opts_map(opts) when is_list(opts) do
    opts
    |> Keyword.new()
    |> Map.new(fn {key, value} -> {normalize_option_key(key), value} end)
  end

  defp normalize_opts_map(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {normalize_option_key(key), value} end)
  end

  defp normalize_opts_map(_opts), do: %{}

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_option_key(key), do: key

  defp codex_additional_directories(llm_config) do
    llm_config
    |> Map.get(:codex_thread_opts, %{})
    |> normalize_opts_map()
    |> Map.get(:additional_directories, [])
    |> case do
      dirs when is_list(dirs) -> dirs
      _ -> []
    end
  end

  defp session_metadata(llm_config) do
    %{
      agent_id: @agent_id,
      prompt_runner: true,
      cwd: llm_config[:cwd]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # -- Legacy timeout helper surface kept for config tests

  defp build_run_opts(llm_config) do
    effective_timeout_ms = resolve_effective_timeout_ms(llm_config)

    []
    |> maybe_put(:context, llm_config[:context])
    |> maybe_put(:continuation, llm_config[:continuation])
    |> maybe_put(:continuation_opts, llm_config[:continuation_opts])
    |> maybe_put(:adapter_opts, timeout: effective_timeout_ms)
  end

  defp resolve_stream_idle_timeout(llm_config) do
    cond do
      positive_timeout?(llm_config[:stream_idle_timeout]) ->
        llm_config[:stream_idle_timeout]

      positive_timeout?(llm_config[:idle_timeout]) ->
        llm_config[:idle_timeout]

      true ->
        max(
          @default_stream_idle_timeout,
          resolve_effective_timeout_ms(llm_config) + @stream_idle_timeout_buffer
        )
    end
  end

  defp resolve_max_stdout_buffer_bytes(llm_config) do
    option_value(llm_config, [:adapter_opts, :max_stdout_buffer_bytes]) ||
      option_value(llm_config, [:adapter_opts, :max_buffer_size]) ||
      1_048_576
  end

  defp resolve_max_stderr_buffer_bytes(llm_config) do
    option_value(llm_config, [:adapter_opts, :max_stderr_buffer_bytes]) ||
      65_536
  end

  defp option_value(llm_config, [section, key]) do
    llm_config
    |> Map.get(section)
    |> normalize_opts_map()
    |> Map.get(key)
  end

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
      provider when provider in [:claude, :codex, :gemini, :amp] -> {:ok, provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_claude_model(nil), do: nil
  defp resolve_claude_model("haiku"), do: "claude-haiku-4-5-20251001"
  defp resolve_claude_model("sonnet"), do: "claude-sonnet-4-5-20250929"
  defp resolve_claude_model("opus"), do: "claude-opus-4-6"
  defp resolve_claude_model(model), do: model

  defp positive_timeout?(value), do: is_integer(value) and value > 0

  defp resolve_effective_timeout_ms(llm_config) do
    llm_config
    |> configured_timeout_candidate()
    |> normalize_timeout_candidate()
    |> clamp_timeout()
  end

  defp configured_timeout_candidate(llm_config) do
    llm_config[:timeout] || adapter_timeout_candidate(llm_config[:adapter_opts])
  end

  defp adapter_timeout_candidate(nil), do: nil

  defp adapter_timeout_candidate(opts) when is_map(opts) do
    Map.get(opts, :timeout) || Map.get(opts, "timeout")
  end

  defp adapter_timeout_candidate(opts) when is_list(opts) do
    case List.keyfind(opts, :timeout, 0) || List.keyfind(opts, "timeout", 0) do
      {_key, timeout} -> timeout
      nil -> nil
    end
  end

  defp adapter_timeout_candidate(_opts), do: nil

  defp normalize_timeout_candidate(nil), do: @emergency_timeout_ms
  defp normalize_timeout_candidate(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp normalize_timeout_candidate(timeout) when timeout in [:unbounded, :infinity],
    do: @emergency_timeout_ms

  defp normalize_timeout_candidate(timeout) when is_binary(timeout) do
    case timeout |> String.trim() |> String.downcase() do
      "unbounded" -> @emergency_timeout_ms
      "infinity" -> @emergency_timeout_ms
      "infinite" -> @emergency_timeout_ms
      value -> parse_numeric_timeout(value)
    end
  end

  defp normalize_timeout_candidate(_timeout), do: @emergency_timeout_ms

  defp parse_numeric_timeout(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> @emergency_timeout_ms
    end
  end

  defp clamp_timeout(timeout) when timeout > @emergency_timeout_ms, do: @emergency_timeout_ms
  defp clamp_timeout(timeout) when timeout > 0, do: timeout
  defp clamp_timeout(_timeout), do: @emergency_timeout_ms

  defp normalize_continuation(nil), do: nil
  defp normalize_continuation(%{} = continuation), do: continuation
  defp normalize_continuation(:auto), do: %{strategy: :latest}
  defp normalize_continuation(:latest), do: %{strategy: :latest}

  defp normalize_continuation(provider_session_id)
       when is_binary(provider_session_id) and provider_session_id != "" do
    %{strategy: :exact, provider_session_id: provider_session_id}
  end

  defp normalize_continuation(_continuation), do: nil

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
