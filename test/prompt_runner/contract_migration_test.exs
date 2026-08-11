defmodule PromptRunner.ContractMigrationTest do
  use ExUnit.Case, async: true

  alias PromptRunner.ContractMigration
  alias PromptRunner.FrontMatter
  alias PromptRunner.Test.FSHelpers

  test "converts quotes and Python snippets into literal argv without a shell" do
    entry = %{
      "repo" => "app",
      "run" => "timeout 120 python3 -c \"print('a;b')\""
    }

    assert {:ok, translated} = ContractMigration.translate_command(entry)
    assert translated["exec"] == "python3"
    assert translated["args"] == ["-c", "print('a;b')"]
    assert translated["timeout_ms"] == 120_000
    refute Map.has_key?(translated, "run")
  end

  test "refuses shell interpreters, pipelines, and implicit glob expansion" do
    assert {:error, :shell_interpreter} =
             ContractMigration.translate_command("timeout 10 bash -c 'mix test'")

    assert {:error, {:shell_operator, "|"}} =
             ContractMigration.translate_command("timeout 10 mix test | grep ok")

    assert {:error, {:implicit_shell_expansion, "*.md"}} =
             ContractMigration.translate_command("timeout 10 ls *.md")
  end

  test "packet migration replaces document and repository scripts with typed clauses" do
    root = FSHelpers.tmp_dir("prompt_runner_contract_migration")
    prompts = Path.join(root, "prompts")
    File.mkdir_p!(prompts)

    file = Path.join(prompts, "01_step.prompt.md")

    File.write!(file, """
    ---
    id: "01"
    phase: 1
    name: "Step"
    verify:
      commands:
        - repo: "brainstorms"
          run: "timeout 120 bin/check_doc.sh report.md 60 '## Verdict'"
        - repo: "brainstorms"
          run: "timeout 300 bin/check_repos.sh app docs"
    ---
    # Step
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %{converted: 2, unresolved: []}} =
             ContractMigration.migrate_packet(root, write: true)

    {:ok, document} = FrontMatter.load_file(file)
    verify = document.attributes["verify"]
    assert verify["commands"] == []

    assert [%{"path" => "report.md", "requires_sections" => ["## Verdict"]}] =
             Enum.map(verify["doc"], &Map.take(&1, ["path", "requires_sections"]))

    assert Enum.map(verify["repos_clean"], & &1["repo"]) == ["app", "docs"]
  end
end
