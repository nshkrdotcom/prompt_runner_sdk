defmodule PromptRunner.LLMFacade do
  @moduledoc """
  Thin delegator implementing the `PromptRunner.LLM` behaviour.

  Normalizes provider names and delegates streaming to `PromptRunner.Session`.
  """

  @behaviour PromptRunner.LLM

  @type sdk :: PromptRunner.LLM.sdk()
  @provider_aliases %{
    "claude" => :claude,
    "claude_agent" => :claude,
    "claude_agent_sdk" => :claude,
    "codex" => :codex,
    "codex_sdk" => :codex,
    "gemini" => :gemini,
    "gemini_cli_sdk" => :gemini,
    "amp" => :amp,
    "amp_sdk" => :amp
  }

  @impl true
  def normalize_provider(nil), do: :claude
  def normalize_provider(v) when is_atom(v), do: normalize_provider(Atom.to_string(v))

  def normalize_provider(v) when is_binary(v) do
    case Map.fetch(@provider_aliases, v |> String.trim() |> String.downcase()) do
      {:ok, provider} ->
        provider

      :error ->
        normalized = v |> String.trim() |> String.downcase()
        {:error, {:invalid_llm_sdk, normalized}}
    end
  end

  def normalize_provider(other), do: {:error, {:invalid_llm_sdk, other}}

  @impl true
  def normalize_sdk(value), do: normalize_provider(value)

  @impl true
  def start_stream(llm, prompt) when is_map(llm) and is_binary(prompt) do
    session_module().start_stream(llm, prompt)
  end

  @impl true
  def resume_stream(llm, meta, prompt)
      when is_map(llm) and is_map(meta) and is_binary(prompt) do
    session_module().resume_stream(llm, meta, prompt)
  end

  defp session_module do
    Application.get_env(:prompt_runner, :session_module, PromptRunner.Session)
  end
end
