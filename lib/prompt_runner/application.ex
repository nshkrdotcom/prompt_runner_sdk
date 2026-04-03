defmodule PromptRunner.Application do
  @moduledoc """
  OTP application for Prompt Runner SDK.

  Session lifecycle management is delegated to the current ASM runtime and the
  provider SDKs beneath it. Prompt runner keeps its own rendering and plan
  orchestration locally.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: PromptRunner.Supervisor)
  end
end
