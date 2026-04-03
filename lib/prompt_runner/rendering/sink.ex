defmodule PromptRunner.Rendering.Sink do
  @moduledoc """
  Behaviour for output destinations that receive rendered prompt-runner text and raw events.
  """

  @type state :: term()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state()} | {:error, term()}
  @callback write(iodata(), state()) :: {:ok, state()} | {:error, term(), state()}

  @callback write_event(event :: map(), iodata(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @callback flush(state()) :: {:ok, state()}
  @callback close(state()) :: :ok
end
