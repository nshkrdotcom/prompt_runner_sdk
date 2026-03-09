defmodule PromptRunner.Run do
  @moduledoc """
  Result returned from `PromptRunner.run/2` and `PromptRunner.run_prompt/2`.
  """

  alias PromptRunner.Plan

  @type t :: %__MODULE__{
          plan: Plan.t(),
          status: :ok | :error,
          result: term()
        }

  defstruct [:plan, :status, :result]
end
