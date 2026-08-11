defmodule PromptRunner.ContractMigration do
  @moduledoc "Safe, explicit conversion of legacy verifier command strings to argv contracts."

  alias PromptRunner.FrontMatter

  @shell_programs ~w(bash sh dash zsh fish)
  @shell_tokens ~w(| || && ; & > >> < << 2> 2>>)

  @spec translate_command(map() | String.t()) :: {:ok, map()} | {:error, term()}
  def translate_command(%{} = entry) do
    entry = stringify_keys(entry)

    cond do
      is_binary(entry["exec"] || entry["program"]) ->
        {:ok, entry}

      is_binary(entry["run"] || entry["command"]) ->
        translate(entry, entry["run"] || entry["command"])

      true ->
        {:error, :command_missing_program}
    end
  end

  def translate_command(command) when is_binary(command), do: translate(%{}, command)
  def translate_command(value), do: {:error, {:invalid_command, value}}

  @spec migrate_packet(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate_packet(packet_root, opts \\ []) do
    files =
      packet_root
      |> Path.expand()
      |> Path.join("prompts/*.prompt.md")
      |> Path.wildcard()
      |> Enum.sort()

    files
    |> Enum.reduce_while({:ok, %{files: 0, converted: 0, unresolved: []}}, fn file,
                                                                              {:ok, report} ->
      case migrate_file(file, opts) do
        {:ok, result} ->
          {:cont,
           {:ok,
            %{
              files: report.files + 1,
              converted: report.converted + result.converted,
              unresolved: report.unresolved ++ result.unresolved
            }}}

        {:error, reason} ->
          {:halt, {:error, {file, reason}}}
      end
    end)
  end

  defp migrate_file(file, opts) do
    with {:ok, document} <- FrontMatter.load_file(file) do
      migrate_document(file, document, opts)
    end
  end

  defp migrate_document(file, document, opts) do
    verify = document.attributes["verify"] || %{}
    commands = List.wrap(verify["commands"] || [])
    {translated, clauses, unresolved, converted} = migrate_commands(commands, file)

    verify =
      Enum.reduce(clauses, Map.put(verify, "commands", translated), fn {key, values}, acc ->
        Map.update(acc, key, values, &(List.wrap(&1) ++ values))
      end)

    attrs = put_in(document.attributes, ["verify"], verify)

    if opts[:write] == true and converted > 0,
      do: FrontMatter.write_file(file, attrs, document.body)

    {:ok, %{converted: converted, unresolved: unresolved}}
  end

  defp migrate_commands(commands, file) do
    commands
    |> Enum.with_index()
    |> Enum.reduce({[], %{}, [], 0}, &migrate_command(&1, &2, file))
  end

  defp migrate_command({entry, index}, {done, clauses, unresolved, count}, file) do
    case semantic_translation(entry) do
      {:ok, additions} ->
        {done, merge_clauses(clauses, additions), unresolved, count + 1}

      :not_semantic ->
        migrate_argv_command(entry, index, done, clauses, unresolved, count, file)
    end
  end

  defp migrate_argv_command(entry, index, done, clauses, unresolved, count, file) do
    case translate_command(entry) do
      {:ok, translated} ->
        {done ++ [translated], clauses, unresolved, count + converted?(entry, translated)}

      {:error, reason} ->
        finding = %{file: file, index: index, command: entry, reason: reason}
        {done ++ [entry], clauses, unresolved ++ [finding], count}
    end
  end

  defp semantic_translation(%{} = raw_entry) do
    entry = stringify_keys(raw_entry)
    command = entry["run"] || entry["command"]

    with true <- is_binary(command),
         {:ok, _timeout_ms, stripped} <- strip_timeout(command),
         {:ok, [program | args]} <- split(stripped) do
      case Path.basename(program) do
        "check_doc.sh" -> doc_translation(entry, args)
        name when name in ["check_repos.sh", "check_repo_clean.sh"] -> repo_translation(args)
        "check_yaml.sh" -> yaml_translation(entry, args)
        _other -> :not_semantic
      end
    else
      _other -> :not_semantic
    end
  end

  defp semantic_translation(_entry), do: :not_semantic

  defp doc_translation(entry, [path, recommended_lines | sections]) do
    min_lines =
      case Integer.parse(recommended_lines) do
        {value, ""} when value >= 0 -> value
        _other -> 1
      end

    {:ok,
     %{
       "doc" => [
         %{
           "repo" => entry["repo"],
           "path" => path,
           "min_lines" => min_lines,
           "requires_sections" => sections
         }
       ]
     }}
  end

  defp doc_translation(_entry, _args), do: :not_semantic

  defp repo_translation(repos) when repos != [] do
    {:ok,
     %{
       "repos_clean" => Enum.map(repos, &%{"repo" => &1, "pushed" => true, "network" => false})
     }}
  end

  defp repo_translation(_repos), do: :not_semantic

  defp yaml_translation(entry, [path | _rest]) do
    {:ok, %{"yaml" => [%{"repo" => entry["repo"], "path" => path}]}}
  end

  defp yaml_translation(_entry, _args), do: :not_semantic

  defp merge_clauses(existing, additions) do
    Map.merge(existing, additions, fn _key, left, right -> left ++ right end)
  end

  defp translate(entry, command) do
    with {:ok, timeout_ms, command} <- strip_timeout(command),
         {:ok, argv} <- split(command),
         [program | args] <- argv,
         :ok <- reject_shell(program, args),
         :ok <- reject_shell_tokens(argv),
         :ok <- reject_implicit_expansion(argv) do
      translated =
        entry
        |> Map.drop(["run", "command"])
        |> Map.put("exec", program)
        |> Map.put("args", args)
        |> Map.put("timeout_ms", timeout_ms)

      {:ok, translated}
    else
      [] -> {:error, :empty_command}
      {:error, _reason} = error -> error
    end
  end

  defp strip_timeout(command) do
    case Regex.run(~r/\Atimeout\s+(\d+)\s+(.+)\z/s, String.trim(command), capture: :all_but_first) do
      [seconds, rest] -> {:ok, String.to_integer(seconds) * 1_000, rest}
      nil -> {:error, :missing_explicit_timeout}
    end
  end

  defp split(command) do
    {:ok, OptionParser.split(command)}
  rescue
    error -> {:error, {:unparseable_command, Exception.message(error)}}
  end

  defp reject_shell(program, args) do
    cond do
      String.ends_with?(program, ".sh") ->
        {:error, :legacy_script}

      Path.basename(program) in @shell_programs and Enum.any?(args, &(&1 in ["-c", "-lc"])) ->
        {:error, :shell_interpreter}

      true ->
        :ok
    end
  end

  defp reject_shell_tokens(argv) do
    case Enum.find(argv, &(&1 in @shell_tokens)) do
      nil -> :ok
      token -> {:error, {:shell_operator, token}}
    end
  end

  defp reject_implicit_expansion(argv) do
    case Enum.find(argv, fn argument ->
           String.contains?(argument, ["$(", "${", "`", "*", "?"])
         end) do
      nil -> :ok
      argument -> {:error, {:implicit_shell_expansion, argument}}
    end
  end

  defp converted?(entry, translated), do: if(entry == translated, do: 0, else: 1)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
