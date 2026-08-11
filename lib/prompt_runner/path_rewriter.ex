defmodule PromptRunner.PathRewriter do
  @moduledoc """
  Rebinds source-checkout paths in packet text to logical workspace paths.

  Packet prose is durable input and often contains absolute paths copied from
  the author's machine. A workspace must never pass those paths through to a
  provider: doing so can send an operator session back into another user's
  checkout. Replacements are longest-first so nested repository roots remain
  deterministic.
  """

  @spec text(term(), %{optional(String.t()) => String.t()}) :: term()
  def text(value, rewrites) when is_binary(value) and is_map(rewrites) do
    rewrites
    |> Enum.reject(fn {source, destination} ->
      not (is_binary(source) and source != "" and is_binary(destination)) or
        source == destination
    end)
    |> Enum.sort_by(fn {source, _destination} -> {-byte_size(source), source} end)
    |> Enum.reduce(value, fn {source, destination}, acc ->
      String.replace(acc, source, destination)
    end)
  end

  def text(value, _rewrites), do: value

  @spec deep(term(), %{optional(String.t()) => String.t()}) :: term()
  def deep(value, rewrites) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, deep(child, rewrites)} end)
  end

  def deep(value, rewrites) when is_list(value), do: Enum.map(value, &deep(&1, rewrites))

  def deep(value, rewrites) when is_tuple(value),
    do: value |> Tuple.to_list() |> deep(rewrites) |> List.to_tuple()

  def deep(value, rewrites), do: text(value, rewrites)
end
