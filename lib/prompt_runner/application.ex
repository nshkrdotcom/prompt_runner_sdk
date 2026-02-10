defmodule PromptRunner.Application do
  @moduledoc """
  OTP application for Prompt Runner SDK.

  Session lifecycle management (stores, adapters, tasks) is handled by
  `AgentSessionManager.StreamSession` — no local supervisors needed.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: PromptRunner.Supervisor)
  end
end
