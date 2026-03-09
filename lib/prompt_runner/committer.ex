defmodule PromptRunner.Committer do
  @moduledoc """
  Behaviour for post-prompt commit or callback actions.
  """

  @callback commit(PromptRunner.Plan.t(), PromptRunner.Prompt.t(), map(), keyword()) :: term()
end
