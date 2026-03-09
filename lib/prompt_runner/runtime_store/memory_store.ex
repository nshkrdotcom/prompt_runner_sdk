defmodule PromptRunner.RuntimeStore.MemoryStore do
  @moduledoc """
  In-memory runtime store used by API-first runs.
  """

  @behaviour PromptRunner.RuntimeStore

  @impl true
  def setup(_plan_or_map) do
    Agent.start_link(fn -> %{} end)
  end

  @impl true
  def statuses(agent) do
    Agent.get(agent, & &1)
  end

  @impl true
  def last_completed(agent) do
    agent
    |> statuses()
    |> Enum.filter(fn {_num, status} -> status.status == "completed" end)
    |> Enum.map(fn {num, _} -> num end)
    |> Enum.sort()
    |> List.last()
  end

  @impl true
  def mark_completed(agent, num, commit_info) do
    Agent.update(agent, fn state ->
      Map.put(state, num, %{
        status: "completed",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        commit: format_commit(commit_info)
      })
    end)
  end

  @impl true
  def mark_failed(agent, num) do
    Agent.update(agent, fn state ->
      Map.put(state, num, %{
        status: "failed",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        commit: nil
      })
    end)
  end

  @impl true
  def log_paths(_state, _num, _timestamp), do: %{log_file: nil, events_file: nil}

  defp format_commit({:ok, sha}), do: sha
  defp format_commit({:skip, reason}), do: to_string(reason)
  defp format_commit(_), do: nil
end
