defmodule PromptRunner.Rendering.Studio.Diff do
  @moduledoc """
  Showing what a tool changed on disk.

  There are two cases, and they are not the same thing.

  **The patch is in the event.** A Claude `Edit` carries `old_string` and
  `new_string`; a `Write` carries the whole `content`. The diff is derivable
  from the event alone — no filesystem access, no ambiguity, and it stays
  correct even if the file changed again afterwards.

  **Only the path is in the event.** A Codex `file_change` item and an
  Antigravity `replace_file_content` name the file and the kind of change and
  nothing else. The honest options are a `git diff` on that path or a stat
  line. A `git diff` is cheap and accurate *at the moment it runs* — but it
  shows the file's current state, which after several edits is not the diff of
  that one tool call.

  **The rule: never present a reconstructed diff as if it were the tool's own
  patch.** At `:stat`, show the path and the change kind. At `:full`, render
  the event's patch where one exists, and where one does not, label the
  rendered `git diff` as the file's current state rather than as that call's
  change.
  """

  alias PromptRunner.Rendering.Studio.ANSI

  @default_line_budget 60

  @type stat :: %{added: non_neg_integer(), removed: non_neg_integer()}

  @doc """
  The line counts for a tool call's change, or `nil` when the event does not
  carry enough to compute them.
  """
  @spec stat(map()) :: stat() | nil
  def stat(tool_info) when is_map(tool_info) do
    case patch_lines(tool_info) do
      nil ->
        nil

      lines ->
        %{
          added: Enum.count(lines, &match?({:add, _}, &1)),
          removed: Enum.count(lines, &match?({:remove, _}, &1))
        }
    end
  end

  @doc """
  A `+12 −3` suffix for a summary line, or `""` when there is nothing to count.
  """
  @spec stat_suffix(map()) :: String.t()
  def stat_suffix(tool_info) do
    case stat(tool_info) do
      nil -> ""
      %{added: 0, removed: 0} -> ""
      %{added: added, removed: removed} -> "  +#{added} −#{removed}"
    end
  end

  @doc """
  The rendered diff body for a tool call, as iodata.

  Options:

  - `:color` — colourize (default `true`)
  - `:indent` — leading spaces (default 4)
  - `:line_budget` — maximum body lines before truncation (default 60)
  - `:cwd` — where to run `git diff` for a path-only change

  Returns `[]` when there is nothing to show. Never silently truncates: a
  truncated diff that looks complete is worse than no diff.
  """
  @spec render(map(), keyword()) :: iodata()
  def render(tool_info, opts \\ []) when is_map(tool_info) do
    case patch_lines(tool_info) do
      nil -> render_current_state(tool_info, opts)
      [] -> []
      lines -> render_lines(lines, nil, opts)
    end
  end

  # -- patch in the event

  defp patch_lines(tool_info) do
    input = Map.get(tool_info, :input) || %{}

    case {tool_kind(tool_info), value(input, "new_string"), value(input, "content")} do
      {:edit, new_string, _content} when is_binary(new_string) ->
        diff_lines(value(input, "old_string") || "", new_string)

      {:write, _new_string, content} when is_binary(content) ->
        diff_lines("", content)

      _other ->
        nil
    end
  end

  @edit_tools ~w(Edit MultiEdit NotebookEdit)
  @write_tools ~w(Write create_file write_to_file)

  defp tool_kind(tool_info) do
    case tool_name(tool_info) do
      name when name in @edit_tools -> :edit
      name when name in @write_tools -> :write
      _other -> :other
    end
  end

  defp tool_name(tool_info) do
    case Map.get(tool_info, :name) do
      name when is_binary(name) -> name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _other -> ""
    end
  end

  # A line-level diff, which is what a reader of an Edit actually wants: the
  # lines that went and the lines that came. Not a minimal edit script — the
  # inputs here are one hunk of a file, and a longest-common-subsequence pass
  # over them buys precision nobody reading a terminal will notice.
  defp diff_lines(old, new) do
    old_lines = split(old)
    new_lines = split(new)

    common_prefix = common_prefix_length(old_lines, new_lines)

    {old_rest, new_rest} =
      {Enum.drop(old_lines, common_prefix), Enum.drop(new_lines, common_prefix)}

    common_suffix = common_prefix_length(Enum.reverse(old_rest), Enum.reverse(new_rest))

    removed = old_rest |> Enum.drop(-common_suffix) |> Enum.map(&{:remove, &1})
    added = new_rest |> Enum.drop(-common_suffix) |> Enum.map(&{:add, &1})

    Enum.map(Enum.take(old_lines, common_prefix), &{:context, &1}) ++
      removed ++
      added ++
      Enum.map(Enum.take(old_rest, -common_suffix), &{:context, &1})
  end

  defp split(""), do: []
  defp split(text) when is_binary(text), do: String.split(text, "\n")
  defp split(_text), do: []

  defp common_prefix_length(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.take_while(fn {a, b} -> a == b end)
    |> length()
  end

  # -- path only

  # `git diff` on the path, explicitly labelled. The label is not decoration:
  # what this shows is the file as it stands now, which after several edits in
  # one turn is not the diff of the call being rendered.
  defp render_current_state(tool_info, opts) do
    with path when is_binary(path) <- changed_path(tool_info),
         cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
         {output, 0} <- git_diff(path, cwd),
         lines when lines != [] <- parse_unified(output) do
      render_lines(lines, "current state of #{path}, not this call's change", opts)
    else
      _other -> []
    end
  end

  defp changed_path(tool_info) do
    input = Map.get(tool_info, :input) || %{}

    value(input, "file_path") || value(input, "path") || value(input, "TargetFile") ||
      value(input, "target_file")
  end

  defp git_diff(path, cwd) do
    System.cmd("git", ["diff", "--no-color", "--", path], cd: cwd, stderr_to_stdout: true)
  catch
    :error, _reason -> {"", 1}
  end

  # Only the body of a unified diff: the `diff --git`, `index`, `---`, `+++`,
  # and `@@` lines say nothing a reader of one file's change needs.
  defp parse_unified(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "@@")))
    |> Enum.map(fn
      "+" <> line -> {:add, line}
      "-" <> line -> {:remove, line}
      " " <> line -> {:context, line}
      line -> {:context, line}
    end)
  end

  # -- rendering

  defp render_lines(lines, label, opts) do
    color = Keyword.get(opts, :color, true)
    indent = String.duplicate(" ", Keyword.get(opts, :indent, 4))
    budget = Keyword.get(opts, :line_budget, @default_line_budget)

    kept = Enum.take(lines, budget)
    dropped = length(lines) - length(kept)

    [
      render_label(label, indent, color),
      Enum.map(kept, &render_line(&1, indent, color)),
      render_truncation(dropped, indent, color)
    ]
  end

  defp render_label(nil, _indent, _color), do: []

  defp render_label(label, indent, color),
    do: [indent, ANSI.dim("(#{label})", color), "\n"]

  defp render_line({:add, text}, indent, color),
    do: [indent, ANSI.green("+ " <> text, color), "\n"]

  defp render_line({:remove, text}, indent, color),
    do: [indent, ANSI.red("- " <> text, color), "\n"]

  defp render_line({:context, text}, indent, color),
    do: [indent, ANSI.dim("  " <> text, color), "\n"]

  defp render_truncation(dropped, _indent, _color) when dropped <= 0, do: []

  defp render_truncation(dropped, indent, color) do
    noun = if dropped == 1, do: "line", else: "lines"
    [indent, ANSI.dim("[truncated: #{dropped} more #{noun}]", color), "\n"]
  end

  defp value(input, key) when is_map(input) do
    case Map.get(input, key) || Map.get(input, atom_key(key)) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp value(_input, _key), do: nil

  # Bounded: tool input is provider data and may not mint atoms.
  @keys %{
    "old_string" => :old_string,
    "new_string" => :new_string,
    "content" => :content,
    "file_path" => :file_path,
    "path" => :path,
    "TargetFile" => :TargetFile,
    "target_file" => :target_file
  }

  defp atom_key(key), do: Map.get(@keys, key)
end
