defmodule PromptRunner.CommitMessages do
  @moduledoc false

  @spec get_message(PromptRunner.Config.t(), String.t(), String.t() | nil) :: String.t() | nil
  def get_message(config, num, repo_name \\ nil) do
    content = File.read!(config.commit_messages_file)

    markers_to_try =
      if repo_name do
        ["=== COMMIT #{num}:#{repo_name} ===", "=== COMMIT #{num} ==="]
      else
        ["=== COMMIT #{num} ==="]
      end

    find_commit_message(content, markers_to_try)
  end

  @spec all_markers(PromptRunner.Config.t()) :: list({String.t(), String.t() | nil})
  def all_markers(config) do
    content = File.read!(config.commit_messages_file)

    ~r/=== COMMIT (\d+)(?::(\w+))? ===/
    |> Regex.scan(content)
    |> Enum.map(fn
      [_, num, repo] -> {num, repo}
      [_, num] -> {num, nil}
    end)
  end

  defp find_commit_message(_content, []), do: nil

  defp find_commit_message(content, [marker | rest]) do
    case String.split(content, marker) do
      [_, after_marker] ->
        msg = extract_message_until_next_marker(after_marker)

        if String.trim(msg) != "" do
          String.trim(msg)
        else
          find_commit_message(content, rest)
        end

      _ ->
        find_commit_message(content, rest)
    end
  end

  defp extract_message_until_next_marker(text) do
    case String.split(text, ~r/\n=== COMMIT /, parts: 2) do
      [msg | _] -> msg
      _ -> text
    end
  end
end
