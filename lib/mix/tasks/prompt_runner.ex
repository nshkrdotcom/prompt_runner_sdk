defmodule Mix.Tasks.PromptRunner do
  @moduledoc """
  Mix task wrapper for the `PromptRunner` CLI.
  """

  @shortdoc "Run PromptRunner commands from Mix"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    PromptRunner.CLI.main(args)
  end
end
