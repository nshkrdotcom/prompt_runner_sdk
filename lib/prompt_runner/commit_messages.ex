defmodule PromptRunner.CommitMessages do
  @moduledoc false

  @spec get_message(PromptRunner.Config.t(), String.t(), String.t() | nil) :: String.t() | nil
  def get_message(source, num, repo_name \\ nil)

  def get_message(%PromptRunner.Plan{commit_messages: messages}, num, repo_name) do
    get_message(messages, num, repo_name)
  end

  def get_message(messages, num, repo_name) when is_map(messages) and not is_struct(messages) do
    if repo_name do
      Map.get(messages, {num, repo_name}) || Map.get(messages, {num, nil})
    else
      Map.get(messages, {num, nil})
    end
  end

  def get_message(config, num, repo_name) do
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
    from_file(config.commit_messages_file)
    |> Map.keys()
  end

  @spec from_file(String.t()) :: %{optional({String.t(), String.t() | nil}) => String.t()}
  def from_file(path) do
    content = File.read!(path)

    Regex.split(~r/^=== COMMIT /m, content, trim: true)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case Regex.run(~r/^(\d+)(?::([\w-]+))? ===\n(.*)\z/s, chunk, capture: :all_but_first) do
        [num, repo, msg] -> Map.put(acc, {num, blank_to_nil(repo)}, String.trim(msg))
        [num, msg] -> Map.put(acc, {num, nil}, String.trim(msg))
        _ -> acc
      end
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
