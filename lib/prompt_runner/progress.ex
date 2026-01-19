defmodule PromptRunner.Progress do
  @moduledoc false

  @spec statuses(PromptRunner.Config.t()) :: map()
  def statuses(config) do
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

  @spec last_completed(PromptRunner.Config.t()) :: String.t() | nil
  def last_completed(config) do
    statuses(config)
    |> Enum.filter(fn {_num, status} -> status.status == "completed" end)
    |> Enum.map(fn {num, _} -> num end)
    |> Enum.sort()
    |> List.last()
  end

  @spec mark_completed(PromptRunner.Config.t(), String.t(), term()) :: :ok
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

  @spec mark_failed(PromptRunner.Config.t(), String.t()) :: :ok
  def mark_failed(config, num) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(config.progress_file, "#{num}:failed:#{timestamp}\n", [:append])
  end

  defp split_progress_suffix(rest) do
    last_segment = rest |> String.split(":") |> List.last()

    cond do
      last_segment in ["no_commit", "no_changes"] ->
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
