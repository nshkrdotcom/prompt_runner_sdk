defmodule PromptRunner.LLM do
  @moduledoc """
  Behaviour and types for LLM integrations.
  """

  @type sdk :: :claude | :codex | :amp | :cursor | :antigravity | :simulated
  @type provider :: sdk()
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> any())

  @callback normalize_provider(term()) :: provider() | {:error, term()}
  @callback normalize_sdk(term()) :: sdk | {:error, term()}
  @callback start_stream(map(), String.t()) ::
              {:ok, stream(), close_fun(), map()} | {:error, term()}

  @callback resume_stream(map(), map(), String.t()) ::
              {:ok, stream(), close_fun(), map()} | {:error, term()}

  @doc """
  Says something to a session that is already running.

  `{:ok, :delivered}` means the text reached the running turn and it continues.
  `{:ok, :interrupted}` means the turn was ended and the caller has to resume
  the provider thread with this text — which lane applies is the provider's
  transport fact, not the caller's choice.
  """
  @callback steer(map(), map(), String.t()) ::
              {:ok, :delivered | :interrupted} | {:error, term()}
end
