defmodule PromptRunner.VerifierDocTest do
  @moduledoc """
  The `doc:` clause is an artifact-quality gate.

  `files_exist` is satisfied by a three-line stub, so a packet whose deliverable
  is a written document has no deterministic way to say "this was actually
  written". `doc:` asserts substance: non-blank content, required sections
  verbatim, and the absence of unresolved authoring markers.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  @manifest_template """
  ---
  name: "doc-packet"
  profile: "codex-default"
  repos:
    app:
      path: "REPO_PATH"
      default: true
  ---
  # Doc Packet
  """

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_doc_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_doc_repo")

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
    end)

    {:ok, repo: repo}
  end

  defp verify(repo, verify_yaml) do
    root =
      FSHelpers.packet!(
        "prompt_runner_doc_packet",
        String.replace(@manifest_template, "REPO_PATH", repo),
        [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write the report"
           targets:
             - "app"
           verify:
           #{verify_yaml}
           ---
           # Write the report
           """}
        ]
      )

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, plan} = PromptRunner.plan(root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))
    {report, Enum.find(report.items, &(&1.kind == "doc"))}
  end

  defp substantive_report do
    body =
      Enum.map_join(1..40, "\n", fn n -> "Paragraph line #{n} of the method section." end)

    """
    # Report

    ## Method

    #{body}

    ## Verdict

    The measurement held.
    """
  end

  test "a substantive document satisfies the gate", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))
    File.write!(Path.join(repo, "docs/report.md"), substantive_report())

    {report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 20
            requires_sections:
              - "## Method"
              - "## Verdict"
      """)

    assert report.pass?
    assert item.pass?
    assert item.repo == "app"
    assert item.path == "docs/report.md"
    assert item.details =~ "ok"
    assert item.details =~ "non-blank lines"
  end

  test "an advisory line suggestion never rejects dense correct work", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(Path.join(repo, "docs/report.md"), """
    # Report

    ## Method

    ## Verdict
    """)

    {report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 100
            requires_sections:
              - "## Method"
              - "## Verdict"
      """)

    assert report.pass?
    assert item.pass?
    assert item.lines == 3
    assert item.min_lines == 100
    assert item.below_recommendation?
    assert item.details =~ "ok: 3 non-blank lines"
  end

  test "a missing required section is named in the details", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(
      Path.join(repo, "docs/report.md"),
      String.replace(substantive_report(), "## Verdict", "## Conclusion")
    )

    {_report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 10
            requires_sections:
              - "## Method"
              - "## Verdict"
      """)

    refute item.pass?
    assert item.missing_sections == ["## Verdict"]
    assert item.details =~ "missing sections: ## Verdict"
    refute item.details =~ "## Method,"
  end

  test "the default forbidden marker set fires without any configuration", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(
      Path.join(repo, "docs/report.md"),
      String.replace(substantive_report(), "The measurement held.", "TODO write this up")
    )

    {_report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 10
      """)

    refute item.pass?
    assert [%{marker: "TODO", line: line}] = item.markers
    assert is_integer(line)
    assert item.details =~ "forbidden markers: TODO (line #{line})"
  end

  test "an explicit empty marker list disables the default set", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(
      Path.join(repo, "docs/report.md"),
      String.replace(substantive_report(), "The measurement held.", "TODO markers are allowed")
    )

    {_report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 10
            forbids_markers: []
      """)

    assert item.pass?
    assert item.markers == []
  end

  test "mentioning a marker in completed prose is not an unfinished stub", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(
      Path.join(repo, "docs/report.md"),
      String.replace(substantive_report(), "The measurement held.", "We removed the TODO marker.")
    )

    {_report, item} =
      verify(repo, """
        doc:
          - "docs/report.md"
      """)

    assert item.pass?
    assert item.markers == []
  end

  test "a custom marker list replaces the default set", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "docs"))

    File.write!(
      Path.join(repo, "docs/report.md"),
      String.replace(substantive_report(), "The measurement held.", "PLACEHOLDER and TODO")
    )

    {_report, item} =
      verify(repo, """
        doc:
          - path: "docs/report.md"
            min_lines: 10
            forbids_markers:
              - "PLACEHOLDER"
      """)

    refute item.pass?
    assert [%{marker: "PLACEHOLDER"}] = item.markers
  end

  test "a missing document fails with a diagnostic detail", %{repo: repo} do
    {_report, item} =
      verify(repo, """
        doc:
          - path: "docs/absent.md"
            min_lines: 10
      """)

    refute item.pass?
    assert item.details =~ "missing"
    assert item.lines == 0
  end

  test "a bare string entry defaults to at least one non-blank line", %{repo: repo} do
    File.write!(Path.join(repo, "EMPTY.md"), "\n\n\n")

    {_report, item} =
      verify(repo, """
        doc:
          - "EMPTY.md"
      """)

    refute item.pass?
    assert item.min_lines == 1
    assert item.details =~ "document is blank"
  end

  test "entries are repo-scoped like every other clause", %{repo: repo} do
    other = FSHelpers.git_repo!("prompt_runner_doc_other")
    on_exit(fn -> File.rm_rf!(other) end)

    File.write!(Path.join(other, "NOTES.md"), substantive_report())

    root =
      FSHelpers.packet!(
        "prompt_runner_doc_scoped_packet",
        """
        ---
        name: "doc-scoped"
        profile: "codex-default"
        repos:
          app:
            path: "#{repo}"
            default: true
          other:
            path: "#{other}"
        ---
        # Doc Scoped
        """,
        [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write"
           targets:
             - "app"
           verify:
             doc:
               - repo: "other"
                 path: "NOTES.md"
                 min_lines: 5
           ---
           # Write
           """}
        ]
      )

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, plan} = PromptRunner.plan(root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))
    item = Enum.find(report.items, &(&1.kind == "doc"))

    assert item.repo == "other"
    assert item.resolved_path == Path.join(other, "NOTES.md")
    assert item.pass?
  end

  test "contract_items exposes doc entries so checklist sync covers them" do
    items =
      Verifier.contract_items(%{
        "doc" => [
          %{"path" => "docs/report.md", "min_lines" => 100},
          %{"repo" => "app", "path" => "docs/other.md"}
        ]
      })

    labels = Enum.map(items, & &1.label)

    assert "doc: docs/report.md (non-blank; 100 lines advisory)" in labels
    assert "doc: app:docs/other.md (non-blank; 1 lines advisory)" in labels
  end
end
