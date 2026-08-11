defmodule PromptRunner.Control.Entry do
  @moduledoc """
  One line of the control log: a command, who issued it, when, and what
  happened to it.

  Every command that reaches the plane gets an entry, including the ones that
  are refused. A refusal that leaves no trace is indistinguishable from a
  command that was never sent.
  """

  @type outcome :: :applied | :rejected | :received

  @type t :: %__MODULE__{
          at: DateTime.t() | nil,
          run_id: String.t() | nil,
          command: String.t() | nil,
          params: map(),
          author: String.t() | nil,
          outcome: outcome() | nil,
          reason: String.t() | nil,
          prompt_id: String.t() | nil,
          attempt: pos_integer() | nil
        }

  defstruct at: nil,
            run_id: nil,
            command: nil,
            params: %{},
            author: nil,
            outcome: nil,
            reason: nil,
            prompt_id: nil,
            attempt: nil

  @outcomes %{"applied" => :applied, "rejected" => :rejected, "received" => :received}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "at" => entry.at && DateTime.to_iso8601(entry.at),
      "run_id" => entry.run_id,
      "command" => entry.command,
      "params" => entry.params,
      "author" => entry.author,
      "outcome" => entry.outcome && to_string(entry.outcome),
      "reason" => entry.reason,
      "prompt_id" => entry.prompt_id,
      "attempt" => entry.attempt
    }
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      at: parse_datetime(map["at"]),
      run_id: map["run_id"],
      command: map["command"],
      params: if(is_map(map["params"]), do: map["params"], else: %{}),
      author: map["author"],
      outcome: map["outcome"] && Map.get(@outcomes, map["outcome"]),
      reason: map["reason"],
      prompt_id: map["prompt_id"],
      attempt: map["attempt"]
    }
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
