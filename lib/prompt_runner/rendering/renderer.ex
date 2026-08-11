defmodule PromptRunner.Rendering.Renderer do
  @moduledoc """
  Behaviour for rendering prompt-runner canonical event maps into human-readable output.
  """

  @type state :: term()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state()} | {:error, term()}
  @callback render_event(event :: map(), state()) :: {:ok, iodata(), state()}
  @callback finish(state()) :: {:ok, iodata(), state()}

  @doc """
  Applies live view settings to a renderer's state, mid-stream.

  Called at an event boundary when a control-plane consumer changes
  `tool_output` or `diff`. A renderer that carries neither can leave this
  unimplemented; `PromptRunner.Rendering` treats its absence as "this renderer
  has nothing to change" rather than as an error, so a view change is never
  fatal to a run.
  """
  @callback set_view(view :: map(), state()) :: {:ok, state()}

  @optional_callbacks set_view: 2
end
