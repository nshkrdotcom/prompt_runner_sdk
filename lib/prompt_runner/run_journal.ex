defmodule PromptRunner.RunJournal do
  @moduledoc """
  Append-only durable run records.

  A journal is never reopened with truncate semantics. Every acknowledged append
  is flushed before returning. Earlier corruption and sequence gaps are errors;
  a single torn final line is quarantined before the next append.
  """

  @schema 1

  @spec append(String.t(), String.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append(path, run_id, type, data \\ %{})
      when is_binary(path) and is_binary(run_id) and is_binary(type) and is_map(data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, seq} <- next_sequence(path),
         record = %{
           schema: @schema,
           run_id: run_id,
           seq: seq,
           at: DateTime.utc_now() |> DateTime.to_iso8601(),
           type: type,
           data: data
         },
         line = Jason.encode!(record) <> "\n",
         :ok <- File.write(path, line, [:append, :binary, :sync]) do
      {:ok, seq}
    end
  end

  @spec read(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, contents} -> decode_records(contents, path, false)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:journal_unreadable, path, reason}}
    end
  end

  defp next_sequence(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, 1}

      {:error, reason} ->
        {:error, {:journal_unreadable, path, reason}}

      {:ok, contents} ->
        with {:ok, records} <- decode_records(contents, path, true) do
          {:ok,
           case List.last(records) do
             nil -> 1
             record -> record["seq"] + 1
           end}
        end
    end
  end

  defp decode_records("", _path, _repair_torn?), do: {:ok, []}

  defp decode_records(contents, path, repair_torn?) do
    terminated? = String.ends_with?(contents, "\n")
    lines = String.split(contents, "\n", trim: false)
    lines = if terminated?, do: Enum.drop(lines, -1), else: lines

    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, records} ->
      decode_record_line(
        Jason.decode(line),
        line,
        line_number,
        records,
        path,
        contents,
        repair_torn? and line_number == length(lines) and not terminated?
      )
    end)
  end

  defp decode_record_line({:ok, record}, _line, line_number, records, path, _contents, _repair?)
       when is_map(record) do
    expected = length(records) + 1

    if valid_record?(record, expected),
      do: {:cont, {:ok, records ++ [record]}},
      else: {:halt, {:error, {:journal_invalid_record, path, line_number}}}
  end

  defp decode_record_line(_error, line, _line_number, records, path, contents, true) do
    case quarantine_torn_tail(path, contents, line) do
      :ok -> {:halt, {:ok, records}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp decode_record_line(_error, _line, line_number, _records, path, _contents, false),
    do: {:halt, {:error, {:journal_corrupt, path, line_number}}}

  defp valid_record?(record, expected_seq) do
    record["schema"] == @schema and record["seq"] == expected_seq and
      is_binary(record["run_id"]) and is_binary(record["type"]) and is_map(record["data"])
  end

  defp quarantine_torn_tail(path, contents, line) do
    good_bytes = byte_size(contents) - byte_size(line)
    good = binary_part(contents, 0, good_bytes)
    quarantine = path <> ".torn.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.write(quarantine, line, [:binary, :sync]) do
      atomic_replace(path, good)
    end
  end

  defp atomic_replace(path, contents) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.write(temp, contents, [:binary, :sync]) do
        File.rename(temp, path)
      end
    after
      _ = File.rm(temp)
    end
  end
end
