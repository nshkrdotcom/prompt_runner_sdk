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
    run_opts =
      []
      |> maybe_put(:context, llm_config[:context])
      |> maybe_put(:continuation, llm_config[:continuation])
      |> maybe_put(:continuation_opts, llm_config[:continuation_opts])

    case llm_config[:timeout] do
      timeout when is_integer(timeout) and timeout > 0 ->
        Keyword.put(run_opts, :adapter_opts, timeout: timeout)

      _ ->
        run_opts
    end
  end

  defp resolve_stream_idle_timeout(llm_config) do
    cond do
      positive_timeout?(llm_config[:stream_idle_timeout]) ->
        llm_config[:stream_idle_timeout]

      positive_timeout?(llm_config[:idle_timeout]) ->
        llm_config[:idle_timeout]

      positive_timeout?(llm_config[:timeout]) ->
        max(@default_stream_idle_timeout, llm_config[:timeout] + @stream_idle_timeout_buffer)

      true ->
        nil
    end
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
