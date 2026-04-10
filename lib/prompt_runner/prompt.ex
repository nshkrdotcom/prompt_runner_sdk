defmodule PromptRunner.Prompt do
  @moduledoc """
  Normalized prompt representation used across all PromptRunner sources.
  """

  @type t :: %__MODULE__{
          num: String.t(),
          phase: integer(),
          sp: integer(),
          name: String.t(),
          file: String.t() | nil,
          body: String.t() | nil,
          origin: map() | nil,
          target_repos: [String.t()] | nil,
          commit_message: String.t() | nil,
          validation_commands: [String.t()],
          verify: map(),
          metadata: map()
        }

  defstruct [
    :num,
    :phase,
    :sp,
    :name,
    :file,
    :body,
    :origin,
    :target_repos,
    :commit_message,
    validation_commands: [],
    verify: %{},
    metadata: %{}
  ]
end
