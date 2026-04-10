defmodule PromptRunner.Source.DirectorySource do
  @moduledoc """
  Source implementation that loads numbered prompt files from a directory.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.FrontMatter
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
    heading_name = metadata["name"] || parse_h1(content)
    mission = parse_mission(content)
    validation = validation_commands(metadata, content)
    {targets, inferred_paths} = parse_targets(metadata, content)
    verify = verify_contract(metadata, validation)
    llm_override = llm_override(metadata)

    num = normalize_num(metadata["id"] || metadata["num"] || filename_num(path) || "01")
    phase = normalize_integer(metadata["phase"], 1)
    sp = normalize_integer(metadata["sp"], 1)

    commit_message =
      metadata["commit"] ||
        auto_commit_message(heading_name || basename_name(path), mission)

    metadata =
      metadata
      |> Map.put("inferred_target_paths", inferred_paths)
      |> Map.put("llm_override", llm_override)

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
      verify: verify,
      metadata: metadata
    }
  end

  defp parse_front_matter(text) do
    case FrontMatter.parse(text) do
      {:ok, %{attributes: metadata, body: content}} -> {metadata, content}
      {:error, _reason} -> {%{}, text}
    end
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
    case metadata["validation"] || get_in(metadata, ["verify", "commands"]) do
      commands when is_list(commands) and commands != [] ->
        Enum.map(commands, fn
          %{"run" => run} -> run
          %{"command" => command} -> command
          other -> to_string(other)
        end)

      _ ->
        parse_validation_commands(text)
    end
  end

  defp verify_contract(metadata, validation_commands) do
    case metadata["verify"] do
      contract when is_map(contract) ->
        stringify_keys(contract)
        |> Map.put_new("commands", validation_commands)

      _ ->
        if validation_commands == [] do
          %{}
        else
          %{"commands" => validation_commands}
        end
    end
  end

  defp llm_override(metadata) do
    metadata
    |> Map.take([
      "provider",
      "model",
      "reasoning_effort",
      "permission_mode",
      "allowed_tools",
      "adapter_opts",
      "claude_opts",
      "codex_opts",
      "codex_thread_opts",
      "gemini_opts",
      "amp_opts",
      "cli_confirmation",
      "timeout",
      "system_prompt",
      "append_system_prompt",
      "max_turns"
    ])
    |> maybe_put_codex_reasoning()
  end

  defp maybe_put_codex_reasoning(%{"reasoning_effort" => value} = attrs)
       when is_binary(value) and value != "" do
    codex_thread_opts =
      attrs
      |> Map.get("codex_thread_opts", %{})
      |> stringify_keys()
      |> Map.put("reasoning_effort", value)

    Map.put(attrs, "codex_thread_opts", codex_thread_opts)
  end

  defp maybe_put_codex_reasoning(attrs), do: attrs

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

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
end
