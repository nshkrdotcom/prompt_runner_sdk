defmodule PromptRunner.Rendering.Renderer do
  @moduledoc """
  Behaviour for rendering prompt-runner canonical event maps into human-readable output.
  """

  @type state :: term()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state()} | {:error, term()}
  @callback render_event(event :: map(), state()) :: {:ok, iodata(), state()}
  @callback finish(state()) :: {:ok, iodata(), state()}
end
