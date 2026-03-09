defmodule PromptRunner.RuntimeStore do
  @moduledoc """
  Behaviour for progress tracking and log destination selection.
  """

  @callback setup(map()) :: {:ok, term()} | {:error, term()}
  @callback statuses(term()) :: map()
  @callback last_completed(term()) :: String.t() | nil
  @callback mark_completed(term(), String.t(), term()) :: :ok
  @callback mark_failed(term(), String.t()) :: :ok
  @callback log_paths(term(), String.t(), String.t()) :: %{
              log_file: String.t() | nil,
              events_file: String.t() | nil
            }
end
