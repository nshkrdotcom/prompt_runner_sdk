defmodule PromptRunner.LLM do
  @moduledoc false

  @type sdk :: :claude | :codex
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> any())

  @callback normalize_sdk(term()) :: sdk | {:error, term()}
  @callback start_stream(map(), String.t()) ::
              {:ok, stream(), close_fun(), map()} | {:error, term()}
end
