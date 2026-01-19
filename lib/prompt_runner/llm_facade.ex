defmodule PromptRunner.LLMFacade do
  @moduledoc false

  @behaviour PromptRunner.LLM

  alias PromptRunner.LLM.CodexNormalizer

  @type sdk :: :claude | :codex

  @impl true
  def normalize_sdk(nil), do: :claude
  def normalize_sdk(v) when is_atom(v), do: normalize_sdk(Atom.to_string(v))

  def normalize_sdk(v) when is_binary(v) do
    case v |> String.trim() |> String.downcase() do
      "claude" -> :claude
      "claude_agent" -> :claude
      "claude_agent_sdk" -> :claude
      "codex" -> :codex
      "codex_sdk" -> :codex
      other -> {:error, {:invalid_llm_sdk, other}}
    end
  end

  def normalize_sdk(other), do: {:error, {:invalid_llm_sdk, other}}

  @impl true
  def start_stream(%{sdk: :claude} = llm, prompt) when is_binary(prompt) do
    ensure_started(:claude)

    opts_kw =
      []
      |> maybe_put(:model, llm[:model])
      |> maybe_put(:allowed_tools, llm[:allowed_tools])
      |> maybe_put(:permission_mode, llm[:permission_mode])
      |> maybe_put(:cwd, llm[:cwd])
      |> Keyword.merge(normalize_kw(llm[:claude_opts]))

    options = ClaudeAgentSDK.Options.new(opts_kw)

    with {:ok, session} <- ClaudeAgentSDK.Streaming.start_session(options) do
      stream = ClaudeAgentSDK.Streaming.send_message(session, prompt)

      close_fun = fn ->
        safe_apply(fn -> ClaudeAgentSDK.Streaming.close_session(session) end)
      end

      {:ok, stream, close_fun, %{sdk: :claude, model: llm[:model], cwd: llm[:cwd]}}
    end
  end

  def start_stream(%{sdk: :codex} = llm, prompt) when is_binary(prompt) do
    ensure_started(:codex)

    codex_opts_map =
      llm[:codex_opts]
      |> normalize_map()
      |> Map.merge(%{})
      |> maybe_put_map(:model, llm[:model])

    thread_opts_map =
      llm[:codex_thread_opts]
      |> normalize_map()
      |> Map.merge(%{working_directory: llm[:cwd]})
      |> maybe_apply_default_codex_controls(llm)

    with {:ok, codex_opts} <- Codex.Options.new(codex_opts_map),
         {:ok, thread_opts} <- Codex.Thread.Options.new(thread_opts_map),
         {:ok, thread} <- Codex.start_thread(codex_opts, thread_opts),
         {:ok, rr} <- Codex.Thread.run_streamed(thread, prompt) do
      raw = Codex.RunResultStreaming.raw_events(rr)
      normalized = CodexNormalizer.normalize(raw, llm[:model])

      close_fun = fn ->
        :ok
      end

      {:ok, normalized, close_fun, %{sdk: :codex, model: llm[:model], cwd: llm[:cwd]}}
    end
  end

  defp normalize_kw(nil), do: []
  defp normalize_kw(list) when is_list(list), do: list

  defp normalize_kw(map) when is_map(map) do
    Enum.map(map, fn {k, v} ->
      key =
        cond do
          is_atom(k) -> k
          is_binary(k) -> String.to_atom(k)
          true -> k
        end

      {key, v}
    end)
  end

  defp maybe_apply_default_codex_controls(thread_opts, llm) do
    pm = llm[:permission_mode]

    thread_opts
    |> maybe_put_if_absent(:ask_for_approval, ask_for_approval_from_permission_mode(pm))
    |> maybe_put_if_absent(:sandbox, sandbox_from_permission_mode(pm))
  end

  defp ask_for_approval_from_permission_mode(nil), do: nil
  defp ask_for_approval_from_permission_mode(:accept_edits), do: :never
  defp ask_for_approval_from_permission_mode(:bypass_permissions), do: :never
  defp ask_for_approval_from_permission_mode(:plan), do: :on_request
  defp ask_for_approval_from_permission_mode(_), do: nil

  defp sandbox_from_permission_mode(nil), do: nil
  defp sandbox_from_permission_mode(:accept_edits), do: :workspace_write
  defp sandbox_from_permission_mode(:bypass_permissions), do: :workspace_write
  defp sandbox_from_permission_mode(:plan), do: :read_only
  defp sandbox_from_permission_mode(_), do: nil

  defp ensure_started(:claude) do
    _ = Application.ensure_all_started(:claude_agent_sdk)
    :ok
  end

  defp ensure_started(:codex) do
    _ = Application.ensure_all_started(:codex_sdk)
    :ok
  end

  defp safe_apply(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(kw) when is_list(kw), do: Enum.into(kw, %{})
  defp normalize_map(_), do: %{}

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp maybe_put_map(map, _k, nil), do: map
  defp maybe_put_map(map, k, v), do: Map.put(map, k, v)

  defp maybe_put_if_absent(map, _k, nil), do: map

  defp maybe_put_if_absent(map, k, v) do
    if Map.has_key?(map, k), do: map, else: Map.put(map, k, v)
  end
end
