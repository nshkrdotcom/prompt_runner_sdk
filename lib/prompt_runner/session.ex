defmodule PromptRunner.Session do
  @moduledoc """
  Bridge between Prompt Runner and AgentSessionManager adapters.

  Starts the appropriate adapter (Claude, Codex, or Amp), runs a single prompt,
  streams canonical ASM events, and provides a cleanup function for resource
  teardown.

  Delegates stream lifecycle management to `AgentSessionManager.StreamSession`.
  """

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.StreamSession
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

  @doc """
  Starts a streaming prompt session and returns a lazy event stream.
  """
  @spec start_stream(llm_config(), String.t()) ::
          {:ok, stream(), close_fun(), map()} | {:error, term()}
  def start_stream(llm_config, prompt) when is_map(llm_config) and is_binary(prompt) do
    with {:ok, provider} <- normalize_provider(llm_config),
         {:ok, adapter_spec} <- build_adapter_spec(provider, llm_config) do
      run_opts = build_run_opts(llm_config)
      idle_timeout = resolve_stream_idle_timeout(llm_config)

      stream_opts =
        []
        |> maybe_put(:adapter, adapter_spec)
        |> maybe_put(:input, %{messages: [%{role: "user", content: prompt}]})
        |> maybe_put(:agent_id, @agent_id)
        |> maybe_put(:run_opts, run_opts)
        |> maybe_put(:idle_timeout, idle_timeout)

      case StreamSession.start(stream_opts) do
        {:ok, stream, close_fun, _stream_meta} ->
          meta = %{
            sdk: provider,
            model: llm_config[:model],
            cwd: llm_config[:cwd]
          }

          {:ok, stream, close_fun, meta}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- Adapter spec builders

  defp build_adapter_spec(:claude, llm_config) do
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

    {:ok, {ClaudeAdapter, opts}}
  end

  defp build_adapter_spec(:codex, llm_config) do
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

      {:ok, {CodexAdapter, opts}}
    end
  end

  defp build_adapter_spec(:amp, llm_config) do
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

      {:ok, {AmpAdapter, opts}}
    end
  end

  # -- Run opts

  defp build_run_opts(llm_config) do
    effective_timeout_ms = resolve_effective_timeout_ms(llm_config)

    run_opts =
      []
      |> maybe_put(:context, llm_config[:context])
      |> maybe_put(:continuation, llm_config[:continuation])
      |> maybe_put(:continuation_opts, llm_config[:continuation_opts])
      |> maybe_put(:adapter_opts, timeout: effective_timeout_ms)

    run_opts
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

  # -- Helpers

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

  defp resolve_claude_model(nil), do: nil
  defp resolve_claude_model("haiku"), do: "claude-haiku-4-5-20251001"
  defp resolve_claude_model("sonnet"), do: "claude-sonnet-4-5-20250929"
  defp resolve_claude_model("opus"), do: "claude-opus-4-6"
  defp resolve_claude_model(model), do: model

  defp normalize_opts(nil), do: []
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.into(opts, [])
  defp normalize_opts(_opts), do: []
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
