defmodule PromptRunner.Verifier.Glob do
  @moduledoc "Read-only glob cardinality and non-empty-file verification."

  @spec report(map(), map()) :: map()
  def report(resolved, entry) do
    matches = Path.wildcard(resolved.resolved_path)
    min_matches = normalize_non_negative(entry["min_matches"], 1)
    max_matches = normalize_non_negative(entry["max_matches"], nil)
    non_empty? = entry["non_empty"] == true

    empty =
      if non_empty?,
        do: Enum.reject(matches, &(File.regular?(&1) and File.stat!(&1).size > 0)),
        else: []

    count_ok? =
      length(matches) >= min_matches and (is_nil(max_matches) or length(matches) <= max_matches)

    %{
      kind: "glob",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path,
      matches: matches,
      pass?: count_ok? and empty == [],
      details: "#{length(matches)} match(es); #{length(empty)} empty/non-file"
    }
  end

  defp normalize_non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative(_value, default), do: default
end
