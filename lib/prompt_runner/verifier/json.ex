defmodule PromptRunner.Verifier.JSON do
  @moduledoc "Read-only JSON syntax and declarative shape verification."

  @spec report(map(), map()) :: map()
  def report(resolved, entry) do
    base = %{
      kind: "json",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path
    }

    with {:ok, contents} <- File.read(resolved.resolved_path),
         {:ok, value} <- Jason.decode(contents) do
      problems =
        []
        |> root_problem(value, entry["root"])
        |> required_path_problems(value, entry["required_paths"] || [])
        |> non_empty_path_problems(value, entry["non_empty_paths"] || [])
        |> array_item_problems(value, entry["array_items_require"] || %{})
        |> forbidden_item_problems(value, entry["array_none_match"] || [])

      Map.merge(base, %{
        pass?: problems == [],
        problems: problems,
        details: if(problems == [], do: "ok", else: Enum.join(problems, "; "))
      })
    else
      {:error, reason} ->
        Map.merge(base, %{
          pass?: false,
          problems: [inspect(reason)],
          details: "JSON read/parse failed: #{inspect(reason)}"
        })
    end
  end

  defp root_problem(problems, _value, nil), do: problems
  defp root_problem(problems, value, "map") when is_map(value), do: problems
  defp root_problem(problems, value, "list") when is_list(value), do: problems
  defp root_problem(problems, _value, expected), do: problems ++ ["root is not #{expected}"]

  defp required_path_problems(problems, value, paths) do
    Enum.reduce(paths, problems, fn path, acc ->
      if fetch_path(value, path) == :missing, do: acc ++ ["missing path #{path}"], else: acc
    end)
  end

  defp non_empty_path_problems(problems, value, paths) do
    Enum.reduce(paths, problems, fn path, acc ->
      case fetch_path(value, path) do
        {:ok, item} when item not in [nil, "", [], %{}] -> acc
        _other -> acc ++ ["empty path #{path}"]
      end
    end)
  end

  defp array_item_problems(problems, value, rules) when is_map(rules) do
    Enum.reduce(rules, problems, fn {path, required_keys}, acc ->
      array_rule_problems(acc, fetch_path(value, path), path, required_keys)
    end)
  end

  defp array_item_problems(problems, _value, _rules),
    do: problems ++ ["array_items_require must be a map"]

  defp array_rule_problems(problems, {:ok, items}, path, required_keys)
       when is_list(items) do
    bad = Enum.reject(items, &valid_array_item?(&1, required_keys))

    if bad == [],
      do: problems,
      else: problems ++ ["#{path} has #{length(bad)} item(s) missing required keys"]
  end

  defp array_rule_problems(problems, _result, path, _required_keys),
    do: problems ++ ["#{path} is not an array"]

  defp valid_array_item?(item, required_keys),
    do: is_map(item) and Enum.all?(required_keys, &Map.has_key?(item, &1))

  defp forbidden_item_problems(problems, value, rules) when is_list(rules) do
    Enum.reduce(rules, problems, fn rule, acc ->
      path = rule["path"]
      field = rule["field"]
      expected = rule["equals"]

      matches =
        case fetch_path(value, path) do
          {:ok, items} when is_list(items) ->
            Enum.count(items, &(is_map(&1) and Map.get(&1, field) == expected))

          _other ->
            0
        end

      if matches == 0,
        do: acc,
        else: acc ++ ["#{path} has #{matches} item(s) where #{field}=#{inspect(expected)}"]
    end)
  end

  defp forbidden_item_problems(problems, _value, _rules),
    do: problems ++ ["array_none_match must be a list"]

  defp fetch_path(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while({:ok, value}, &fetch_segment/2)
  end

  defp fetch_path(_value, _path), do: :missing

  defp fetch_segment(segment, {:ok, current}) when is_map(current) do
    case Map.fetch(current, segment) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :missing}
    end
  end

  defp fetch_segment(_segment, {:ok, _current}), do: {:halt, :missing}
end
