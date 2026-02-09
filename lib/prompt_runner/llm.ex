defmodule PromptRunner.LLM do
  @moduledoc """
  Behaviour and types for LLM integrations.
  """

  @type sdk :: :claude | :codex | :amp
  @type provider :: sdk()
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> any())

  @callback normalize_provider(term()) :: provider() | {:error, term()}
  @callback normalize_sdk(term()) :: sdk | {:error, term()}
  @callback start_stream(map(), String.t()) ::
              {:ok, stream(), close_fun(), map()} | {:error, term()}
end
