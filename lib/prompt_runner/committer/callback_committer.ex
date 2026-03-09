defmodule PromptRunner.Committer.CallbackCommitter do
  @moduledoc """
  Committer that delegates post-run handling to a callback function.
  """

  @behaviour PromptRunner.Committer

  @impl true
  def commit(plan, prompt, llm, opts) do
    callback = opts[:callback] || opts[:fun]

    if is_function(callback, 3) do
      callback.(plan, prompt, llm)
    else
      {:skip, :noop}
    end
  end
end
