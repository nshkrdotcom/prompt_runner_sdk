defmodule PromptRunner.LLM do
  @moduledoc """
  Behaviour and types for LLM integrations.

  This module defines the common interface for LLM backends (Claude and Codex)
  and the shared types used across the prompt runner.
  """

  @type sdk :: :claude | :codex
  @type stream_event :: map()
  @type stream :: Enumerable.t()
  @type close_fun :: (-> any())

  @callback normalize_sdk(term()) :: sdk | {:error, term()}
  @callback start_stream(map(), String.t()) ::
              {:ok, stream(), close_fun(), map()} | {:error, term()}
end
