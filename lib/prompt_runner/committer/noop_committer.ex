defmodule PromptRunner.Committer.NoopCommitter do
  @moduledoc """
  Committer that records no post-run git or callback action.
  """

  @behaviour PromptRunner.Committer

  @impl true
  def commit(_plan, _prompt, _llm, _opts), do: {:skip, :noop}
end
