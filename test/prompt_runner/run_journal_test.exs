defmodule PromptRunner.RunJournalTest do
  use ExUnit.Case, async: true

  alias PromptRunner.RunJournal
  alias PromptRunner.Test.FSHelpers

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_journal")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, path: Path.join(root, "journal.jsonl")}
  end

  test "reopening appends without truncating prior records", %{path: path} do
    assert {:ok, 1} = RunJournal.append(path, "run", "created", %{value: 1})
    first_size = File.stat!(path).size
    assert {:ok, 2} = RunJournal.append(path, "run", "running", %{value: 2})
    assert File.stat!(path).size > first_size

    assert {:ok, [first, second]} = RunJournal.read(path)
    assert first["seq"] == 1
    assert second["seq"] == 2
  end

  test "a torn final record is quarantined before the next durable append", %{path: path} do
    assert {:ok, 1} = RunJournal.append(path, "run", "created")
    File.write!(path, ~s({"schema":1,"run_id":"run"), [:append])

    assert {:ok, 2} = RunJournal.append(path, "run", "resumed")
    assert {:ok, records} = RunJournal.read(path)
    assert Enum.map(records, & &1["seq"]) == [1, 2]
    assert [_quarantine] = Path.wildcard(path <> ".torn.*")
  end

  test "earlier corruption is rejected", %{path: path} do
    File.write!(
      path,
      "broken\n" <>
        Jason.encode!(%{schema: 1, run_id: "run", seq: 2, type: "x", data: %{}}) <> "\n"
    )

    assert {:error, {:journal_corrupt, ^path, 1}} = RunJournal.read(path)
    assert {:error, {:journal_corrupt, ^path, 1}} = RunJournal.append(path, "run", "next")
  end
end
