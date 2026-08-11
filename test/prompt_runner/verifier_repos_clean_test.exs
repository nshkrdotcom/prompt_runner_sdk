defmodule PromptRunner.VerifierReposCleanTest do
  @moduledoc """
  The `repos_clean:` clause asserts that sessions committed their own work.

  When a packet runs with `--no-commit` the runner's committer never runs and
  `changed_paths_only` passes vacuously, because the session has already
  committed and `git status --porcelain` is empty. `repos_clean:` is the check
  that actually holds such a packet to account, and with `pushed: true` it also
  holds it to the upstream.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_clean_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_clean_repo")

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
        "prompt_runner_clean_packet",
        """
        ---
        name: "clean-packet"
        profile: "codex-default"
        repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Clean Packet
        """,
        [
          {"01_commit.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Commit the work"
           targets:
             - "app"
           verify:
           #{verify_yaml}
           ---
           # Commit the work
           """}
        ]
      )

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, plan} = PromptRunner.plan(root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))
    {report, Enum.find(report.items, &(&1.kind == "repos_clean"))}
  end

  test "a committed repository with no upstream passes by default", %{repo: repo} do
    {report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
      """)

    assert report.pass?
    assert item.pass?
    assert item.repo == "app"
    assert item.details =~ "no upstream"
  end

  test "a bare repo name is accepted", %{repo: repo} do
    {_report, item} =
      verify(repo, """
        repos_clean:
          - "app"
      """)

    assert item.pass?
    assert item.repo == "app"
  end

  test "an uncommitted change fails and the details name the paths", %{repo: repo} do
    File.write!(Path.join(repo, "scratch.txt"), "not committed\n")
    File.write!(Path.join(repo, "README.md"), "# Repo\n\nedited\n")

    {report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
      """)

    refute report.pass?
    refute item.pass?
    assert item.dirty_count == 2
    assert item.details =~ "uncommitted changes"
    assert item.details =~ "scratch.txt"
    assert item.details =~ "README.md"
  end

  test "pushed: true fails when the branch has no upstream", %{repo: repo} do
    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
            pushed: true
      """)

    refute item.pass?
    assert item.details =~ "no upstream"
    assert item.details =~ "pushed: true"
  end

  test "pushed: true passes when HEAD equals the upstream", %{repo: repo} do
    remote = FSHelpers.bare_repo!("prompt_runner_clean_remote")
    on_exit(fn -> File.rm_rf!(remote) end)
    branch = FSHelpers.push_to_origin!(repo, remote)

    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
            pushed: true
      """)

    assert item.pass?
    assert item.branch == branch
    assert item.details =~ "pushed"
  end

  test "pushed: true fails when a commit was never pushed", %{repo: repo} do
    remote = FSHelpers.bare_repo!("prompt_runner_clean_remote")
    on_exit(fn -> File.rm_rf!(remote) end)
    FSHelpers.push_to_origin!(repo, remote)
    FSHelpers.commit_file!(repo, "NOTES.md", "# Notes\n")

    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
            pushed: true
      """)

    refute item.pass?
    assert item.details =~ "not pushed"
    assert item.details =~ item.head
  end

  test "an unknown repo name fails rather than passing vacuously", %{repo: repo} do
    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "nope"
      """)

    refute item.pass?
    assert item.details =~ "missing_repo"
  end

  test "a path that is not a git repository fails", %{repo: _repo} do
    plain = FSHelpers.tmp_dir("prompt_runner_clean_plain")
    on_exit(fn -> File.rm_rf!(plain) end)

    {_report, item} =
      verify(plain, """
        repos_clean:
          - repo: "app"
      """)

    refute item.pass?
    assert item.details =~ "not a git repository"
  end

  test "verification never mutates the repository", %{repo: repo} do
    remote = FSHelpers.bare_repo!("prompt_runner_clean_remote")
    on_exit(fn -> File.rm_rf!(remote) end)
    FSHelpers.push_to_origin!(repo, remote)

    before_head = FSHelpers.git!(repo, ["rev-parse", "HEAD"])
    before_branches = FSHelpers.git!(repo, ["branch", "--list"])
    before_status = FSHelpers.git!(repo, ["status", "--porcelain"])
    before_remote_refs = FSHelpers.git!(repo, ["for-each-ref", "refs/remotes"])

    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
            pushed: true
      """)

    assert item.pass?
    assert FSHelpers.git!(repo, ["rev-parse", "HEAD"]) == before_head
    assert FSHelpers.git!(repo, ["branch", "--list"]) == before_branches
    assert FSHelpers.git!(repo, ["status", "--porcelain"]) == before_status
    assert FSHelpers.git!(repo, ["for-each-ref", "refs/remotes"]) == before_remote_refs
  end

  test "verification does not move remote-tracking refs", %{repo: repo} do
    # The assertion above cannot bite while the cached ref already matches the
    # remote. Move the remote ahead from a second clone, so a `git fetch` would
    # visibly rewrite `refs/remotes/origin/*`, and prove it does not happen.
    # An explicitly networked `git ls-remote` answers the same question without
    # writing anything.
    remote = FSHelpers.bare_repo!("prompt_runner_clean_remote")
    on_exit(fn -> File.rm_rf!(remote) end)
    branch = FSHelpers.push_to_origin!(repo, remote)

    other = FSHelpers.clone!(remote, "prompt_runner_clean_clone")
    on_exit(fn -> File.rm_rf!(other) end)
    FSHelpers.commit_file!(other, "FROM_ELSEWHERE.md", "# Elsewhere\n")
    FSHelpers.git!(other, ["push", "-q", "origin", branch])

    remote_tip = FSHelpers.git!(other, ["rev-parse", "HEAD"])
    cached_before = FSHelpers.git!(repo, ["rev-parse", "origin/#{branch}"])
    refute cached_before == remote_tip

    {_report, item} =
      verify(repo, """
        repos_clean:
          - repo: "app"
            pushed: true
            network: true
      """)

    assert FSHelpers.git!(repo, ["rev-parse", "origin/#{branch}"]) == cached_before

    # And the verdict used the live remote, not the stale cached ref: HEAD
    # matches the cached ref exactly, so a cache-based comparison would have
    # passed.
    refute item.pass?
    assert item.details =~ "not pushed"
    assert item.details =~ String.slice(remote_tip, 0, 7)
  end

  test "contract_items exposes repos_clean entries so checklist sync covers them" do
    items =
      Verifier.contract_items(%{
        "repos_clean" => [
          %{"repo" => "app"},
          %{"repo" => "docs", "pushed" => true},
          "lib"
        ]
      })

    labels = Enum.map(items, & &1.label)

    assert "repo committed: app" in labels
    assert "repo committed and pushed: docs" in labels
    assert "repo committed: lib" in labels
  end
end
