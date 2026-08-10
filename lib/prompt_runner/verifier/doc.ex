defmodule PromptRunner.Verifier.Doc do
  @moduledoc """
  The `doc:` verify clause: an artifact-quality gate for written deliverables.

  `files_exist` is satisfied by a three-line stub, so a prompt whose deliverable
  is a document has no deterministic way to assert the document was actually
  written. `doc:` asserts substance instead of presence:

  ```yaml
  verify:
    doc:
      - path: "docs/report.md"
        min_lines: 100
        requires_sections: ["## Method", "## Verdict"]
        forbids_markers: ["TODO", "TBD", "FIXME"]
  ```

  - `min_lines` counts **non-blank** lines and defaults to 1, so a bare
    `doc: ["docs/report.md"]` still rejects an empty file.
  - `requires_sections` matches verbatim substrings, so heading level and
    wording are both asserted.
  - `forbids_markers` defaults to `#{inspect(~w(TODO TBD FIXME XXX))}`. An
    explicit empty list disables the check; a custom list replaces the default
    rather than extending it.

  Entries are repo-scoped exactly like every other clause, either with a
  `repo:` key or through the prompt's default repository.
  """

  @default_markers ~w(TODO TBD FIXME XXX)
  @default_min_lines 1

  @doc "Returns the default forbidden marker set applied when `forbids_markers` is omitted."
  @spec default_markers() :: [String.t()]
  def default_markers, do: @default_markers

  @doc """
  Builds the verifier report item for one `doc:` entry.

  `resolved` is the repo-scoped `%{repo:, path:, resolved_path:}` map produced
  by the verifier's shared entry resolution.
  """
  @spec report(map(), term()) :: map()
  def report(resolved, entry) do
    spec = spec(entry)

    case File.read(resolved.resolved_path) do
      {:ok, content} -> content_report(resolved, spec, content)
      {:error, reason} -> unreadable_report(resolved, spec, reason)
    end
  end

  @doc "Returns the effective non-blank line floor for an entry."
  @spec min_lines(term()) :: non_neg_integer()
  def min_lines(entry), do: spec(entry).min_lines

  defp spec(entry) when is_map(entry) do
    %{
      min_lines: normalize_min_lines(Map.get(entry, "min_lines")),
      requires_sections: normalize_strings(Map.get(entry, "requires_sections")),
      forbids_markers: normalize_markers(entry)
    }
  end

  defp spec(_entry) do
    %{
      min_lines: @default_min_lines,
      requires_sections: [],
      forbids_markers: @default_markers
    }
  end

  defp normalize_min_lines(value) when is_integer(value) and value >= 0, do: value

  defp normalize_min_lines(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> @default_min_lines
    end
  end

  defp normalize_min_lines(_value), do: @default_min_lines

  defp normalize_markers(entry) do
    case Map.fetch(entry, "forbids_markers") do
      {:ok, nil} -> @default_markers
      {:ok, markers} -> normalize_strings(markers)
      :error -> @default_markers
    end
  end

  defp normalize_strings(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_strings(value) when is_binary(value), do: [value]
  defp normalize_strings(_values), do: []

  defp content_report(resolved, spec, content) do
    lines = non_blank_lines(content)
    missing = Enum.reject(spec.requires_sections, &String.contains?(content, &1))
    markers = markers(content, spec.forbids_markers)
    problems = problems(lines, spec.min_lines, missing, markers)

    base(resolved, spec)
    |> Map.merge(%{
      lines: lines,
      missing_sections: missing,
      markers: markers,
      pass?: problems == [],
      details: details(problems, lines)
    })
  end

  defp unreadable_report(resolved, spec, reason) do
    base(resolved, spec)
    |> Map.merge(%{
      lines: 0,
      missing_sections: spec.requires_sections,
      markers: [],
      pass?: false,
      details: unreadable_details(reason, resolved.resolved_path)
    })
  end

  defp base(resolved, spec) do
    %{
      kind: "doc",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path,
      min_lines: spec.min_lines
    }
  end

  defp unreadable_details(:enoent, path), do: "missing file: #{path}"
  defp unreadable_details(reason, path), do: "unreadable file (#{reason}): #{path}"

  defp non_blank_lines(content) do
    content
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) != ""))
  end

  defp markers(content, markers) do
    numbered =
      content
      |> String.split("\n")
      |> Enum.with_index(1)

    Enum.flat_map(markers, fn marker -> marker_hit(numbered, marker) end)
  end

  defp marker_hit(numbered, marker) do
    case Enum.find(numbered, fn {line, _number} -> String.contains?(line, marker) end) do
      {_line, number} -> [%{marker: marker, line: number}]
      nil -> []
    end
  end

  defp problems(lines, min_lines, missing, markers) do
    []
    |> line_problem(lines, min_lines)
    |> section_problem(missing)
    |> marker_problem(markers)
  end

  defp line_problem(problems, lines, min_lines) when lines < min_lines do
    problems ++ ["#{lines} non-blank lines, needs #{min_lines}"]
  end

  defp line_problem(problems, _lines, _min_lines), do: problems

  defp section_problem(problems, []), do: problems

  defp section_problem(problems, missing) do
    problems ++ ["missing sections: #{Enum.join(missing, ", ")}"]
  end

  defp marker_problem(problems, []), do: problems

  defp marker_problem(problems, markers) do
    formatted = Enum.map_join(markers, ", ", fn hit -> "#{hit.marker} (line #{hit.line})" end)
    problems ++ ["forbidden markers: #{formatted}"]
  end

  defp details([], lines), do: "ok: #{lines} non-blank lines"
  defp details(problems, _lines), do: Enum.join(problems, "; ")
end
