defmodule PromptRunner.RuntimeStore.NoopStore do
  @moduledoc """
  No-op runtime store for integrations that do not want persisted state.
  """

  @behaviour PromptRunner.RuntimeStore

  @impl true
  def setup(_plan_or_map), do: {:ok, %{}}

  @impl true
  def statuses(_state), do: %{}

  @impl true
  def last_completed(_state), do: nil

  @impl true
  def mark_completed(_state, _num, _commit_info), do: :ok

  @impl true
  def mark_failed(_state, _num), do: :ok

  @impl true
  def log_paths(_state, _num, _timestamp), do: %{log_file: nil, events_file: nil}
end
