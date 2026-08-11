defmodule PromptRunner.Verifier.Yaml do
  @moduledoc "Read-only YAML syntax and root-shape verification."

  @spec report(map(), map()) :: map()
  def report(resolved, entry) do
    base = base(resolved)

    case YamlElixir.read_from_file(resolved.resolved_path) do
      {:ok, value} ->
        expected = Map.get(entry, "root")
        shape_ok? = root_matches?(value, expected)

        Map.merge(base, %{
          pass?: shape_ok?,
          root: root_type(value),
          details:
            if(shape_ok?, do: "ok", else: "expected root #{expected}, got #{root_type(value)}")
        })

      {:error, reason} ->
        Map.merge(base, %{
          pass?: false,
          details: "YAML parse failed: #{inspect(reason)}"
        })
    end
  rescue
    error ->
      Map.merge(base(resolved), %{
        pass?: false,
        details: "YAML parse failed: #{Exception.message(error)}"
      })
  end

  defp base(resolved) do
    %{
      kind: "yaml",
      repo: resolved.repo,
      path: resolved.path,
      resolved_path: resolved.resolved_path
    }
  end

  defp root_matches?(_value, nil), do: true
  defp root_matches?(value, "map"), do: is_map(value)
  defp root_matches?(value, "list"), do: is_list(value)
  defp root_matches?(value, "scalar"), do: not is_map(value) and not is_list(value)
  defp root_matches?(_value, _expected), do: false

  defp root_type(value) when is_map(value), do: "map"
  defp root_type(value) when is_list(value), do: "list"
  defp root_type(_value), do: "scalar"
end
