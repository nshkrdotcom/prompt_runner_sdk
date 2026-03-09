defmodule PromptRunner.RuntimeStore.FileStore do
  @moduledoc """
  File-backed runtime store used by CLI and legacy runs.
  """

  @behaviour PromptRunner.RuntimeStore

  @impl true
  def setup(%{config: config, runtime_config: runtime_config}) do
    {:ok,
     %{
       progress_file: runtime_config[:progress_file] || config.progress_file,
       log_dir: runtime_config[:log_dir] || config.log_dir
     }}
  end

  def setup(%{config: config}) do
    {:ok,
     %{
       progress_file: config.progress_file,
       log_dir: config.log_dir
     }}
  end

  @impl true
  def statuses(%{progress_file: progress_file}) do
    case File.read(progress_file) do
      {:ok, content} -> parse_progress_content(content)
      {:error, _} -> %{}
    end
  end

  @impl true
  def last_completed(state) do
    state
    |> statuses()
    |> Enum.filter(fn {_num, status} -> status.status == "completed" end)
    |> Enum.map(fn {num, _} -> num end)
    |> Enum.sort()
    |> List.last()
  end

  @impl true
  def mark_completed(%{progress_file: progress_file}, num, commit_info) do
    File.mkdir_p!(Path.dirname(progress_file))
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    File.write!(progress_file, "#{num}:completed:#{timestamp}#{commit_suffix(commit_info)}\n", [
      :append
    ])
  end

  @impl true
  def mark_failed(%{progress_file: progress_file}, num) do
    File.mkdir_p!(Path.dirname(progress_file))
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.write!(progress_file, "#{num}:failed:#{timestamp}\n", [:append])
  end

  @impl true
  def log_paths(%{log_dir: log_dir}, num, timestamp) do
    File.mkdir_p!(log_dir)

    %{
      log_file: Path.join(log_dir, "prompt-#{num}-#{timestamp}.log"),
      events_file: Path.join(log_dir, "prompt-#{num}-#{timestamp}.events.jsonl")
    }
  end

  defp commit_suffix(results) when is_list(results) do
    formatted =
      results
      |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
      |> Enum.map_join(",", fn {repo, {:ok, sha}} -> "#{repo}=#{sha}" end)

    if formatted == "", do: ":no_changes", else: ":#{formatted}"
  end

  defp commit_suffix({:ok, sha}) when is_binary(sha), do: ":#{sha}"
  defp commit_suffix({:skip, reason}) when is_atom(reason), do: ":#{reason}"
  defp commit_suffix({:skip, reason}) when is_binary(reason), do: ":#{reason}"
  defp commit_suffix(_), do: ""

  defp split_progress_suffix(rest) do
    last_segment = rest |> String.split(":") |> List.last()

    cond do
      last_segment in ["no_commit", "no_changes", "noop"] ->
        {String.trim_trailing(rest, ":" <> last_segment), last_segment}

      last_segment =~ ~r/^[0-9a-fA-F]{7,40}$/ ->
        {String.trim_trailing(rest, ":" <> last_segment), last_segment}

      true ->
        {rest, nil}
    end
  end

  defp parse_progress_content(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 3) do
        [num, status, rest] ->
          {timestamp, commit} = split_progress_suffix(rest)
          Map.put(acc, num, %{status: status, timestamp: timestamp, commit: commit})

        _ ->
          acc
      end
    end)
  end
end
