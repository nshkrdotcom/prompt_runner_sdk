defmodule PromptRunner.Prompt do
  @moduledoc false

  @type t :: %__MODULE__{
          num: String.t(),
          phase: integer(),
          sp: integer(),
          name: String.t(),
          file: String.t(),
          target_repos: [String.t()] | nil
        }

  defstruct [:num, :phase, :sp, :name, :file, :target_repos]
end
