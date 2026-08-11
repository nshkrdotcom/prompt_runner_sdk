defmodule PromptRunner.PacketLintTest do
  @moduledoc """
  Every check here corresponds to a way a packet silently misbehaves at
  runtime. Each one is exercised against a constructed violation, because a
  gate nobody has watched fail is not known to work.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.PacketLint
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_lint_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_lint_repo")
    docs = FSHelpers.git_repo!("prompt_runner_lint_docs")

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
      File.rm_rf!(docs)
    end)

    {:ok, repo: repo, docs: docs}
  end

  defp manifest(repo, docs) do
    """
    ---
    name: "lint-packet"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
      docs:
        path: "#{docs}"
    ---
    # Lint Packet
    """
  end

  defp lint(repo, docs, prompts, opts \\ []) do
    root = FSHelpers.packet!("prompt_runner_lint_packet", manifest(repo, docs), prompts)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, report} = PacketLint.lint(root, opts)
    report
  end

  defp kinds(report), do: Enum.map(report.findings, & &1.kind)

  defp finding(report, kind), do: Enum.find(report.findings, &(&1.kind == kind))

  defp clean_prompt(id \\ "01", file \\ "01_write.prompt.md") do
    {file,
     """
     ---
     id: "#{id}"
     phase: 1
     name: "Write notes"
     targets:
       - "app"
     verify:
       files_exist:
         - "NOTES.md"
       commands:
         - exec: test
           args: ["-f", "NOTES.md"]
           timeout_ms: 60000
     ---
     # Write notes

     ## Mission

     Write NOTES.md.
     """}
  end

  test "a well-formed packet produces no findings", %{repo: repo, docs: docs} do
    report = lint(repo, docs, [clean_prompt()])

    assert report.findings == []
    assert report.errors == 0
    assert report.warnings == 0
    assert report.pass?
    assert report.packet == "lint-packet"
  end

  test "an unwrapped verify command is a warning", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         verify:
           commands:
             - "mix test"
             - run: "timeout 900 mix dialyzer"
         ---
         # Write notes
         """}
      ])

    assert "verify_command_without_timeout" in kinds(report)
    found = finding(report, "verify_command_without_timeout")
    assert found.severity == "warning"
    assert found.message =~ "mix test"
    assert found.message =~ "no timeout"
    refute found.message =~ "dialyzer"
    assert report.pass?
  end

  test "a bounded structured command avoids legacy-shell and timeout findings", %{
    repo: repo,
    docs: docs
  } do
    report = lint(repo, docs, [clean_prompt()])

    refute "legacy_shell_command" in kinds(report)
    refute "verify_command_without_timeout" in kinds(report)
  end

  test "strict lint rejects a legacy shell command", %{repo: repo, docs: docs} do
    report =
      lint(
        repo,
        docs,
        [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Legacy"
           targets: ["app"]
           verify:
             commands:
               - "timeout 60 mix test"
           ---
           # Legacy
           """}
        ],
        strict: true
      )

    refute report.pass?
    assert finding(report, "legacy_shell_command").severity == "error"
  end

  test "an id that does not match the filename prefix is an error", %{repo: repo, docs: docs} do
    report = lint(repo, docs, [clean_prompt("02", "01_write.prompt.md")])

    found = finding(report, "prompt_id_filename_mismatch")
    assert found.severity == "error"
    assert found.file == "01_write.prompt.md"
    assert found.message =~ "02"
    assert found.message =~ "01"
    refute report.pass?
    assert report.errors == 1
  end

  test "a filename with no numeric prefix is an error", %{repo: repo, docs: docs} do
    report = lint(repo, docs, [clean_prompt("01", "write.prompt.md")])

    found = finding(report, "prompt_filename_without_prefix")
    assert found.severity == "error"
    assert found.message =~ "numeric prefix"
    refute report.pass?
  end

  test "duplicate prompt ids are an error", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        clean_prompt("01", "01_write.prompt.md"),
        clean_prompt("01", "02_write_again.prompt.md")
      ])

    found = finding(report, "duplicate_prompt_id")
    assert found.severity == "error"
    assert found.message =~ "01"
    assert found.message =~ "01_write.prompt.md"
    assert found.message =~ "02_write_again.prompt.md"
    refute report.pass?
  end

  test "an unknown repo in targets is an error", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
           - "nope"
         verify:
           files_exist:
             - "NOTES.md"
           commands:
             - "timeout 60 true"
         ---
         # Write notes
         """}
      ])

    found = finding(report, "unknown_target_repo")
    assert found.severity == "error"
    assert found.message =~ "nope"
    assert found.message =~ "app"
    assert found.message =~ "docs"
    refute report.pass?
  end

  test "an unknown repo in a verify entry is an error", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         verify:
           files_exist:
             - repo: "ghost"
               path: "NOTES.md"
           commands:
             - repo: "app"
               run: "timeout 60 true"
         ---
         # Write notes
         """}
      ])

    found = finding(report, "unknown_verify_repo")
    assert found.severity == "error"
    assert found.message =~ "ghost"
    assert found.message =~ "files_exist"
    refute report.pass?
  end

  test "the packet repo alias is accepted in a verify entry", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         verify:
           files_exist:
             - repo: "packet"
               path: "README.md"
           commands:
             - "timeout 60 true"
         ---
         # Write notes
         """}
      ])

    refute "unknown_verify_repo" in kinds(report)
  end

  test "a repo group reference in targets is an error", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "@core"
         verify:
           files_exist:
             - "NOTES.md"
           commands:
             - "timeout 60 true"
         ---
         # Write notes
         """}
      ])

    found = finding(report, "repo_group_in_targets")
    assert found.severity == "error"
    assert found.message =~ "@core"
    assert found.message =~ "legacy"
    refute "unknown_target_repo" in kinds(report)
    refute report.pass?
  end

  test "a prompt with no verify contract is a warning", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         ---
         # Write notes
         """}
      ])

    found = finding(report, "prompt_without_verify")
    assert found.severity == "warning"
    assert found.message =~ "provider"
    assert report.pass?
    refute "contract_without_commands" in kinds(report)
  end

  test "a contract with no commands entry is a warning", %{repo: repo, docs: docs} do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         verify:
           files_exist:
             - "NOTES.md"
         ---
         # Write notes
         """}
      ])

    found = finding(report, "contract_without_commands")
    assert found.severity == "warning"
    assert found.message =~ "empty file"
    assert report.pass?
  end

  test "a contract that asserts content is not warned about", %{repo: repo, docs: docs} do
    # `contains`, `matches`, and `doc` are each unsatisfiable by an empty file,
    # so the missing-commands warning would be false for a contract using them.
    for clause <- [
          ~s(  contains:\n    - path: "NOTES.md"\n      text: "done"),
          ~s(  matches:\n    - path: "NOTES.md"\n      pattern: "done"),
          ~s(  doc:\n    - path: "NOTES.md"\n      min_lines: 20)
        ] do
      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             files_exist:
               - "NOTES.md"
           #{clause}
           ---
           # Write notes
           """}
        ])

      refute "contract_without_commands" in kinds(report), "warned for #{clause}"
    end
  end

  test "changed_paths_only is always reported, whatever the commit arrangement", %{
    repo: repo,
    docs: docs
  } do
    # Lint cannot see how a packet is run, and a check that only fires once
    # someone has already declared `--no-commit` is close to useless: the
    # packets most likely to get this wrong are the ones that never say so.
    prompts = [
      {"01_write.prompt.md",
       """
       ---
       id: "01"
       phase: 1
       name: "Write notes"
       targets:
         - "app"
       verify:
         changed_paths_only:
           - "NOTES.md"
         commands:
           - "timeout 60 true"
       ---
       # Write notes
       """}
    ]

    report = lint(repo, docs, prompts)
    found = finding(report, "changed_paths_only_vacuous")

    assert found.severity == "warning"
    assert report.pass?

    # Both halves must be readable in one pass: the mechanism, and the exact
    # condition under which the clause is still the right one.
    assert found.message =~ "git status --porcelain"
    assert found.message =~ "still uncommitted"
    assert found.message =~ "correct when the runner owns the commit"
    assert found.message =~ "--no-commit"
    assert found.message =~ "committer: noop"
    assert found.message =~ "repos_clean"

    # And it is promoted like any other warning.
    strict = lint(repo, docs, prompts, strict: true)
    assert finding(strict, "changed_paths_only_vacuous").severity == "error"
  end

  test "a contract without changed_paths_only is not warned about", %{repo: repo, docs: docs} do
    report = lint(repo, docs, [clean_prompt()])

    refute "changed_paths_only_vacuous" in kinds(report)
  end

  test "inert front-matter keys are reported with the reason they are inert", %{
    repo: repo,
    docs: docs
  } do
    report =
      lint(repo, docs, [
        {"01_write.prompt.md",
         """
         ---
         id: "01"
         phase: 1
         name: "Write notes"
         targets:
           - "app"
         references:
           - "docs/adr-001.md"
         required_reading:
           - "docs/adr-001.md"
         context_files:
           - "workspace/README.md"
         depends_on:
           - "00"
         verify:
           files_exist:
             - "NOTES.md"
           commands:
             - "timeout 60 true"
         ---
         # Write notes
         """}
      ])

    inert = Enum.filter(report.findings, &(&1.kind == "inert_front_matter_key"))
    keys = Enum.map(inert, & &1.key)

    assert Enum.sort(keys) == ["context_files", "references", "required_reading"]
    assert Enum.all?(inert, &(&1.severity == "warning"))

    references = Enum.find(inert, &(&1.key == "references"))
    assert references.message =~ "never sent to the provider"

    refute "depends_on" in keys
  end

  test "strict promotes warnings to errors", %{repo: repo, docs: docs} do
    prompts = [
      {"01_write.prompt.md",
       """
       ---
       id: "01"
       phase: 1
       name: "Write notes"
       targets:
         - "app"
       verify:
         files_exist:
           - "NOTES.md"
         commands:
           - "mix test"
       ---
       # Write notes
       """}
    ]

    lenient = lint(repo, docs, prompts)
    assert lenient.pass?
    assert lenient.warnings > 0
    assert lenient.errors == 0

    strict = lint(repo, docs, prompts, strict: true)
    refute strict.pass?
    assert strict.warnings == 0
    assert strict.errors == lenient.warnings
    assert Enum.all?(strict.findings, &(&1.severity == "error"))
  end

  test "a freshly scaffolded prompt carries no inert front-matter keys", %{repo: repo} do
    root = FSHelpers.tmp_dir("prompt_runner_lint_scaffold")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, packet} =
             PromptRunner.Packet.new("demo",
               root: root,
               repos: [{"app", repo}],
               default_repo: "app"
             )

    assert {:ok, _path} =
             PromptRunner.Packets.create_prompt(packet.root, %{
               "id" => "01",
               "phase" => 1,
               "name" => "Write notes",
               "targets" => ["app"]
             })

    assert {:ok, report} = PacketLint.lint(packet.root, [])

    refute "inert_front_matter_key" in kinds(report)
    assert report.pass?
  end

  describe "verify command paths" do
    test "a future script is not rejected before the prompt can create it", %{
      repo: repo,
      docs: docs
    } do
      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - "timeout 60 bin/check_doc.sh"
           ---
           # Write notes
           """}
        ])

      refute "verify_command_missing_path" in kinds(report)
      assert report.pass?
    end

    test "a script that exists under the prompt's repo is fine", %{repo: repo, docs: docs} do
      File.mkdir_p!(Path.join(repo, "bin"))
      File.write!(Path.join([repo, "bin", "check_doc.sh"]), "#!/bin/sh\nexit 0\n")

      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - "timeout 60 bin/check_doc.sh"
           ---
           # Write notes
           """}
        ])

      refute "verify_command_missing_path" in kinds(report)
    end

    test "the cwd is the entry's repo, not the prompt's target", %{repo: repo, docs: docs} do
      File.mkdir_p!(Path.join(docs, "bin"))
      File.write!(Path.join([docs, "bin", "check_doc.sh"]), "#!/bin/sh\nexit 0\n")

      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - repo: "docs"
                 run: "timeout 60 bin/check_doc.sh"
           ---
           # Write notes
           """}
        ])

      refute "verify_command_missing_path" in kinds(report)
    end

    # A check that guesses produces false errors on correct packets and gets
    # turned off, so anything it cannot resolve is left alone.
    test "tokens that are not resolvable paths are left alone", %{repo: repo, docs: docs} do
      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - "timeout 60 mix test"
               - "timeout 60 curl -sf https://example.com/x/y.sh"
               - "timeout 60 bash $HOME/bin/thing.sh"
               - "timeout 60 ls docs/*/bin/thing.sh"
               - "timeout 60 grep -R foo/bar lib"
           ---
           # Write notes
           """}
        ])

      refute "verify_command_missing_path" in kinds(report)
    end

    test "a future relative executable is left to post-session verification", %{
      repo: repo,
      docs: docs
    } do
      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - "timeout 60 ./bin/verify"
           ---
           # Write notes
           """}
        ])

      refute "verify_command_missing_path" in kinds(report)
    end

    test "an unresolvable repo yields the repo finding only, not a path finding", %{
      repo: repo,
      docs: docs
    } do
      report =
        lint(repo, docs, [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           verify:
             commands:
               - repo: "nowhere"
                 run: "timeout 60 bin/check_doc.sh"
           ---
           # Write notes
           """}
        ])

      assert "unknown_verify_repo" in kinds(report)
      refute "verify_command_missing_path" in kinds(report)
    end
  end

  test "lint reports a packet that cannot be loaded" do
    root = FSHelpers.tmp_dir("prompt_runner_lint_missing")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, _reason} = PacketLint.lint(root, [])
  end
end
