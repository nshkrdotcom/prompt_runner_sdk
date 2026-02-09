defmodule PromptRunner.Application do
  @moduledoc """
  OTP application for Prompt Runner SDK.

  Starts a supervision tree with `Task.Supervisor` (for prompt execution) and
  `DynamicSupervisor` (for adapter lifecycle).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: PromptRunner.TaskSupervisor},
      {DynamicSupervisor, name: PromptRunner.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PromptRunner.Supervisor)
  end
end
