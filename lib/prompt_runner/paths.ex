defmodule PromptRunner.Paths do
  @moduledoc false

  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(path, base_dir \\ nil)

  def resolve(nil, _base_dir), do: nil

  def resolve(path, base_dir) when is_binary(path) do
    path
    |> expand(base_dir)
    |> canonicalize()
  end

  defp expand(path, base_dir) do
    cond do
      Path.type(path) == :absolute -> Path.expand(path)
      is_binary(base_dir) -> Path.expand(path, base_dir)
      true -> Path.expand(path)
    end
  end

  defp canonicalize(path) do
    case Path.split(path) do
      [root | rest] -> walk(root, rest)
      [] -> path
    end
  end

  defp walk(current, []), do: current

  defp walk(current, [segment | rest]) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        candidate
        |> resolve_link_target()
        |> walk(rest)

      {:ok, _stat} ->
        walk(candidate, rest)

      {:error, _reason} ->
        Path.join(current, Path.join([segment | rest]))
    end
  end

  defp resolve_link_target(path) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(path))
          end

        canonicalize(target)

      {:error, _reason} ->
        path
    end
  end
end
