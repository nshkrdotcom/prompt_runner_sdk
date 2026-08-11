defmodule PromptRunner.Progress do
  @moduledoc false

  alias PromptRunner.Config
  alias PromptRunner.Plan

  @type source :: Plan.t() | Config.t()

  @spec statuses(source()) :: map()
  def statuses(%Plan{runtime_store: {module, state}}) do
    module.statuses(state)
  end

  def statuses(%Config{} = config) do
    case File.read(config.progress_file) do
      {:ok, content} ->
        parse_progress_content(content)

      {:error, _} ->
        %{}
    end
  end

  @spec status(map(), String.t()) :: map()
  def status(statuses, num) do
    Map.get(statuses, num, %{status: "pending", timestamp: nil, commit: nil})
  end

  @spec completed?(map(), String.t()) :: boolean()
  def completed?(statuses, num) do
    status(statuses, num).status == "completed"
  end

  @doc """
  The prompts in `nums` whose recorded status is not `completed`, in order.

  This is the question a resume actually asks. `last_completed/1` answers a
  different one — where the run got to — and resuming from there steps over any
  earlier prompt that failed or never ran.

  A prompt with no recorded status is remaining: absence of a record is not
  evidence of success. If the progress store cannot be read at all, every
  prompt is remaining, because a resume that silently runs nothing is worse
  than one that re-verifies finished work.
  """
  @spec remaining(source(), [String.t()]) :: [String.t()]
  def remaining(source, nums) when is_list(nums) do
    statuses = statuses(source)
    Enum.reject(nums, &completed?(statuses, &1))
  end

  @spec last_completed(source()) :: String.t() | nil
  def last_completed(%Plan{runtime_store: {module, state}}) do
    module.last_completed(state)
  end

  def last_completed(config) do
    statuses(config)
    |> Enum.filter(fn {_num, status} -> status.status == "completed" end)
    |> Enum.map(fn {num, _} -> num end)
    |> Enum.sort()
    |> List.last()
  end

  @spec mark_completed(source(), String.t(), term()) :: :ok
  def mark_completed(%Plan{runtime_store: {module, state}}, num, commit_info) do
    module.mark_completed(state, num, commit_info)
  end

  def mark_completed(config, num, commit_info) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    commit_suffix =
      case commit_info do
        results when is_list(results) ->
          formatted =
            results
            |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
            |> Enum.map_join(",", fn {repo, {:ok, sha}} -> "#{repo}=#{sha}" end)

          if formatted == "", do: ":no_changes", else: ":#{formatted}"

        {:ok, sha} when is_binary(sha) ->
          ":#{sha}"

        {:skip, reason} when is_atom(reason) ->
          ":#{reason}"

        {:skip, reason} when is_binary(reason) ->
          ":#{reason}"

        _ ->
          ""
      end

    File.write!(config.progress_file, "#{num}:completed:#{timestamp}#{commit_suffix}\n", [:append])
  end

  @spec mark_failed(source(), String.t()) :: :ok
  def mark_failed(%Plan{runtime_store: {module, state}}, num) do
    module.mark_failed(state, num)
  end

  def mark_failed(config, num) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(config.progress_file, "#{num}:failed:#{timestamp}\n", [:append])
  end

  defp split_progress_suffix(rest) do
    last_segment = rest |> String.split(":") |> List.last()

    cond do
      last_segment in ["no_commit", "no_changes", "no_session"] ->
        {String.trim_trailing(rest, ":" <> last_segment), last_segment}

      last_segment =~ ~r/^[0-9a-fA-F]{7,40}$/ ->
        {String.trim_trailing(rest, ":" <> last_segment), last_segment}

      true ->
        {rest, nil}
    end
  end

  defp parse_progress_line(line) do
    case String.split(line, ":", parts: 3) do
      [num, status, rest] ->
        {timestamp, commit} = split_progress_suffix(rest)
        {:ok, num, status, timestamp, commit}

      _ ->
        :error
    end
  end

  defp parse_progress_content(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_progress_line(line) do
        {:ok, num, status, timestamp, commit} ->
          Map.put(acc, num, %{status: status, timestamp: timestamp, commit: commit})

        :error ->
          acc
      end
    end)
  end
end
