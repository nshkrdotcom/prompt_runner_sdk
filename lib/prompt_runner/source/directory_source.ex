defmodule PromptRunner.Source.DirectorySource do
  @moduledoc """
  Source implementation that loads numbered prompt files from a directory.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.Prompt
  alias PromptRunner.Source.Result

  @impl true
  def load(dir, _opts) when is_binary(dir) do
    files = prompt_files(dir)

    inferred_targets = %{}

    {prompts, commit_messages, inferred_targets} =
      Enum.reduce(files, {[], %{}, inferred_targets}, fn path, {prompts, messages, targets} ->
        prompt = build_prompt(path)
        messages = maybe_put_commit_message(messages, prompt)
        targets = merge_targets(targets, infer_targets(prompt))
        {[prompt | prompts], messages, targets}
      end)

    {:ok,
     %Result{
       prompts: Enum.reverse(prompts),
       commit_messages: commit_messages,
       target_repos: targets_from_map(inferred_targets),
       source_root: dir,
       project_dir: dir
     }}
  end

  defp prompt_files(dir) do
    prompt_md =
      dir
      |> Path.join("*.prompt.md")
      |> Path.wildcard()
      |> Enum.sort_by(&sort_key/1)

    if prompt_md == [] do
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort_by(&sort_key/1)
    else
      prompt_md
    end
  end

  defp build_prompt(path) do
    body = File.read!(path)
    {metadata, content} = parse_front_matter(body)
    heading_name = parse_h1(content)
    mission = parse_mission(content)
    validation = validation_commands(metadata, content)
    {targets, inferred_paths} = parse_targets(metadata, content)

    num = normalize_num(metadata["num"] || filename_num(path) || "01")
    phase = normalize_integer(metadata["phase"], 1)
    sp = normalize_integer(metadata["sp"], 1)

    commit_message =
      metadata["commit"] ||
        auto_commit_message(heading_name || basename_name(path), mission)

    metadata = Map.put(metadata, "inferred_target_paths", inferred_paths)

    %Prompt{
      num: num,
      phase: phase,
      sp: sp,
      name: heading_name || basename_name(path),
      file: Path.basename(path),
      body: content,
      origin: %{type: :file, path: path},
      target_repos: targets,
      commit_message: commit_message,
      validation_commands: validation,
      metadata: metadata
    }
  end

  defp parse_front_matter(text) do
    case Regex.run(~r/\A---\n(.*?)\n---\n/s, text, capture: :all_but_first) do
      [front_matter] ->
        metadata = parse_simple_yaml(front_matter)
        content = String.replace_prefix(text, "---\n#{front_matter}\n---\n", "")
        {metadata, content}

      _ ->
        {%{}, text}
    end
  end

  defp parse_simple_yaml(text) do
    lines = String.split(text, "\n", trim: true)

    Enum.reduce(lines, {%{}, nil}, &parse_yaml_line/2)
    |> elem(0)
  end

  defp parse_yaml_line(line, {acc, current_list_key}) do
    cond do
      String.starts_with?(line, "  - ") and current_list_key ->
        append_yaml_list_item(acc, current_list_key, line)

      String.contains?(line, ":") ->
        parse_yaml_key_value(acc, line)

      true ->
        {acc, current_list_key}
    end
  end

  defp append_yaml_list_item(acc, current_list_key, line) do
    item = line |> String.replace_prefix("  - ", "") |> strip_quotes()
    updated = Map.update(acc, current_list_key, [item], &(&1 ++ [item]))
    {updated, current_list_key}
  end

  defp parse_yaml_key_value(acc, line) do
    [raw_key, raw_value] = String.split(line, ":", parts: 2)
    key = String.trim(raw_key)
    value = parse_yaml_value(String.trim(raw_value))
    {Map.put(acc, key, value), next_list_key(value, key)}
  end

  defp parse_yaml_value(""), do: []

  defp parse_yaml_value(value) do
    if String.starts_with?(value, "[") and String.ends_with?(value, "]") do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",", trim: true)
      |> Enum.map(&(String.trim(&1) |> strip_quotes()))
    else
      strip_quotes(value)
    end
  end

  defp next_list_key([], key), do: key
  defp next_list_key(_value, _key), do: nil

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp parse_h1(text) do
    case Regex.run(~r/^#\s+(.+)$/m, text, capture: :all_but_first) do
      [name] -> String.trim(name)
      _ -> nil
    end
  end

  defp parse_mission(text) do
    case Regex.run(~r/^##\s+Mission\s*\n+(.+?)(?:\n##\s|\z)/ms, text, capture: :all_but_first) do
      [mission] ->
        mission
        |> String.trim()
        |> String.split("\n\n")
        |> List.first()
        |> String.trim()

      _ ->
        nil
    end
  end

  defp parse_validation_commands(text) do
    case Regex.run(~r/^##\s+Validation Commands\s*\n+(.+?)(?:\n##\s|\z)/ms, text,
           capture: :all_but_first
         ) do
      [commands] ->
        commands
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("-")
          |> String.trim()
          |> String.trim_leading("`")
          |> String.trim_trailing("`")
        end)

      _ ->
        []
    end
  end

  defp validation_commands(metadata, text) do
    case metadata["validation"] do
      commands when is_list(commands) and commands != [] ->
        Enum.map(commands, &to_string/1)

      _ ->
        parse_validation_commands(text)
    end
  end

  defp parse_targets(metadata, text) do
    if is_list(metadata["targets"]) do
      {Enum.map(metadata["targets"], &to_string/1), []}
    else
      case parse_repository_roots(text) do
        [] ->
          {nil, []}

        repo_roots ->
          {Enum.map(repo_roots, &repo_name_for_root/1), repo_roots}
      end
    end
  end

  defp parse_repository_roots(text) do
    case Regex.run(~r/^##\s+Repository Root\s*\n+(.+?)(?:\n##\s|\z)/ms, text,
           capture: :all_but_first
         ) do
      [roots] ->
        roots
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("-")
          |> String.trim()
          |> String.trim_leading("`")
          |> String.trim_trailing("`")
        end)

      _ ->
        []
    end
  end

  defp infer_targets(%Prompt{metadata: %{"inferred_target_paths" => paths}, target_repos: repos})
       when is_list(paths) and is_list(repos) do
    Enum.zip(repos, paths)
    |> Enum.into(%{}, fn {name, path} -> {name, %{name: name, path: path, default: false}} end)
  end

  defp infer_targets(_prompt), do: %{}

  defp merge_targets(left, right), do: Map.merge(left, right)

  defp targets_from_map(map) when map_size(map) == 0, do: nil

  defp targets_from_map(map) do
    map
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> mark_first_default()
  end

  defp mark_first_default([]), do: []
  defp mark_first_default([first | rest]), do: [%{first | default: true} | rest]

  defp maybe_put_commit_message(messages, %Prompt{num: num, commit_message: msg})
       when is_binary(msg) and msg != "" do
    Map.put(messages, {num, nil}, msg)
  end

  defp maybe_put_commit_message(messages, _prompt), do: messages

  defp auto_commit_message(_name, mission) when is_binary(mission) and mission != "" do
    first_line = mission |> String.split("\n") |> List.first() |> String.trim()

    if String.contains?(String.downcase(first_line), ":") or
         String.starts_with?(first_line, "feat"),
       do: first_line,
       else: "feat: #{first_line}"
  end

  defp auto_commit_message(name, _mission), do: "feat: #{name}"

  defp sort_key(path) do
    base = Path.basename(path)
    num = filename_num(path) || "9999"
    {String.pad_leading(num, 6, "0"), base}
  end

  defp filename_num(path) do
    case Regex.run(~r/^(\d+)/, Path.basename(path), capture: :all_but_first) do
      [num] -> num
      _ -> nil
    end
  end

  defp basename_name(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> Path.rootname()
    |> String.replace(~r/^\d+[-_]?/, "")
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.trim()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_num(num) when is_integer(num),
    do: num |> Integer.to_string() |> String.pad_leading(2, "0")

  defp normalize_num(num) when is_binary(num) do
    num
    |> String.trim()
    |> String.to_integer()
    |> normalize_num()
  end

  defp normalize_integer(nil, default), do: default
  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp repo_name_for_root(root) do
    root
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end
end
