defmodule PromptRunner.Verifier.SourceAbsent do
  @moduledoc "Read-only assertion that forbidden regexes are absent from declared source paths."

  @default_prune ~w(.git _build deps node_modules .elixir_ls cover)

  @spec report(map(), map()) :: map()
  def report(resolved, entry) do
    patterns = List.wrap(entry["patterns"] || entry["pattern"] || [])
    include_extensions = List.wrap(entry["extensions"] || [])
    prune = @default_prune ++ List.wrap(entry["prune"] || [])

    cond do
      patterns == [] -> failure(resolved, "source_absent requires at least one pattern")
      not File.exists?(resolved.resolved_path) -> failure(resolved, "source path is missing")
      true -> do_report(resolved, patterns, include_extensions, prune)
    end
  end

  defp do_report(resolved, patterns, include_extensions, prune) do
    case compile_patterns(patterns) do
      {:ok, regexes} ->
        source_report(resolved, include_extensions, prune, regexes)

      {:error, reason} ->
        failure(resolved, "invalid source_absent pattern: #{inspect(reason)}")
    end
  end

  defp source_report(resolved, include_extensions, prune, regexes) do
    files = source_files(resolved.resolved_path, include_extensions, prune)
    findings = Enum.flat_map(files, &file_findings(&1, regexes))

    %{
      kind: "source_absent",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path,
      files_checked: length(files),
      findings: findings,
      pass?: findings == [],
      details:
        if(findings == [], do: "ok", else: "#{length(findings)} forbidden source match(es)")
    }
  end

  defp file_findings(file, regexes) do
    file
    |> File.stream!(:line, [])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} -> line_findings(file, line, number, regexes) end)
  end

  defp line_findings(file, line, number, regexes) do
    Enum.flat_map(regexes, fn {source, regex} ->
      if Regex.match?(regex, line),
        do: [%{file: file, line: number, pattern: source, text: String.trim(line)}],
        else: []
    end)
  end

  defp failure(resolved, details) do
    %{
      kind: "source_absent",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path,
      pass?: false,
      findings: [],
      details: details
    }
  end

  defp compile_patterns(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn source, {:ok, acc} ->
      case Regex.compile(to_string(source), "u") do
        {:ok, regex} -> {:cont, {:ok, acc ++ [{to_string(source), regex}]}}
        {:error, reason} -> {:halt, {:error, {source, reason}}}
      end
    end)
  end

  defp source_files(path, extensions, prune) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> walk(path, extensions, prune)
      true -> []
    end
  end

  defp walk(path, extensions, prune) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in prune))
        |> Enum.flat_map(&source_entry_files(path, &1, extensions, prune))

      {:error, _reason} ->
        []
    end
  end

  defp source_entry_files(path, entry, extensions, prune) do
    child = Path.join(path, entry)

    cond do
      File.dir?(child) and not symlink?(child) -> walk(child, extensions, prune)
      File.regular?(child) and extension_allowed?(child, extensions) -> [child]
      true -> []
    end
  end

  defp extension_allowed?(_path, []), do: true
  defp extension_allowed?(path, extensions), do: Path.extname(path) in extensions
  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
