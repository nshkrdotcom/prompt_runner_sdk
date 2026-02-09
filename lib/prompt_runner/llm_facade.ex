defmodule PromptRunner.LLMFacade do
  @moduledoc """
  Thin delegator implementing the `PromptRunner.LLM` behaviour.

  Normalizes provider names and delegates streaming to `PromptRunner.Session`.
  """

  @behaviour PromptRunner.LLM

  @type sdk :: PromptRunner.LLM.sdk()

  @impl true
  def normalize_provider(nil), do: :claude
  def normalize_provider(v) when is_atom(v), do: normalize_provider(Atom.to_string(v))

  def normalize_provider(v) when is_binary(v) do
    case v |> String.trim() |> String.downcase() do
      "claude" -> :claude
      "claude_agent" -> :claude
      "claude_agent_sdk" -> :claude
      "codex" -> :codex
      "codex_sdk" -> :codex
      "amp" -> :amp
      "amp_sdk" -> :amp
      other -> {:error, {:invalid_llm_sdk, other}}
    end
  end

  def normalize_provider(other), do: {:error, {:invalid_llm_sdk, other}}

  @impl true
  def normalize_sdk(value), do: normalize_provider(value)

  @impl true
  def start_stream(llm, prompt) when is_map(llm) and is_binary(prompt) do
    session_module().start_stream(llm, prompt)
  end

  defp session_module do
    Application.get_env(:prompt_runner, :session_module, PromptRunner.Session)
  end
end
