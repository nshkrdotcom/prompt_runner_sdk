defmodule PromptRunner.WatchTest do
  @moduledoc """
  `watch` reports supervision facts, not judgements.

  The two things it must not repeat from the shell prototypes it replaces: it
  must not decide liveness from a process-name match (that matched the
  supervisor's own shell and reported a healthy run forever), and it must not
  decide quiet time by parsing the event stream (the JSONL schema differs
  between `events_mode: compact` and `full`, and a parser written against one
  reported zero for the other).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.CLI
  alias PromptRunner.Paths
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Watch

  # Above the default pid_max, so it can never name a live process.
  @dead_pid "2147483646"

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_watch_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_watch_repo")

    root =
      FSHelpers.packet!(
        "prompt_runner_watch_packet",
        """
        ---
        name: "watch-packet"
        profile: "codex-default"
        repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Watch Packet
        """,
        [
          {"01_noop.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Noop"
           targets:
             - "app"
           verify:
             files_exist:
               - "README.md"
           ---
           # Noop
           """}
        ]
      )

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
      File.rm_rf!(root)
    end)

    {:ok, root: root, repo: repo}
  end

  defp write_pid(root, pid) do
    state_dir = Paths.state_dir(root)
    File.mkdir_p!(state_dir)
    File.write!(Paths.pid_file(state_dir), pid <> "\n")
  end

  test "with no pid file the runner reads as down", %{root: root} do
    assert {:ok, sample} = Watch.sample(root)

    assert sample.runner == :down
    assert sample.pid == nil
    assert sample.prompt == nil
    assert sample.repos == 1
    assert sample.dirty == 0
    assert sample.commits == 1
  end

  test "a pid file naming a live process reads as up", %{root: root} do
    write_pid(root, System.pid())

    assert {:ok, sample} = Watch.sample(root)
    assert sample.runner == :up
    assert sample.pid == String.to_integer(System.pid())
  end

  test "a pid file naming a dead process reads as down", %{root: root} do
    write_pid(root, @dead_pid)

    assert {:ok, sample} = Watch.sample(root)
    assert sample.runner == :down
    assert sample.pid == String.to_integer(@dead_pid)
  end

  test "an unreadable pid file reads as down rather than crashing", %{root: root} do
    write_pid(root, "not-a-pid")

    assert {:ok, sample} = Watch.sample(root)
    assert sample.runner == :down
    assert sample.pid == nil
  end

  test "dirty counts uncommitted paths across the configured repos", %{
    root: root,
    repo: repo
  } do
    File.write!(Path.join(repo, "scratch.txt"), "wip\n")
    File.write!(Path.join(repo, "README.md"), "# Repo\n\nedited\n")

    assert {:ok, sample} = Watch.sample(root)
    assert sample.dirty == 2
  end

  test "commits sums the commit count across the configured repos", %{root: root, repo: repo} do
    FSHelpers.commit_file!(repo, "NOTES.md", "# Notes\n")

    assert {:ok, sample} = Watch.sample(root)
    assert sample.commits == 2
  end

  test "quiet is derived from mtimes, not from the event stream", %{root: root, repo: repo} do
    log_dir = Paths.state_dir(root) |> Path.join("logs")
    File.mkdir_p!(log_dir)

    # Both event schemas, and a stale mtime on each, so a parser that read
    # either one would report a stale run. The freshest byte is in the repo.
    stale = System.os_time(:second) - 3 * 3600

    compact = Path.join(log_dir, "prompt-01-20260101-000000.events.jsonl")
    File.write!(compact, ~s({"e":{"t":"tu"},"t":1786332318176}\n))
    File.touch!(compact, stale)

    full = Path.join(log_dir, "prompt-02-20260101-000000.events.jsonl")
    File.write!(full, ~s({"data":{},"ts":"2026-01-01T00:00:00Z"}\n))
    File.touch!(full, stale)

    File.write!(Path.join(repo, "fresh.txt"), "just written\n")

    assert {:ok, sample} = Watch.sample(root)
    assert sample.quiet_minutes == 0

    File.rm!(Path.join(repo, "fresh.txt"))
    File.touch!(Path.join(repo, "README.md"), stale)
    File.touch!(Path.join(repo, ".git"), stale)

    assert {:ok, stale_sample} = Watch.sample(root)
    assert stale_sample.quiet_minutes >= 179
  end

  test "prompt is read from the newest prompt log", %{root: root} do
    log_dir = Paths.state_dir(root) |> Path.join("logs")
    File.mkdir_p!(log_dir)

    older = Path.join(log_dir, "prompt-04-20260101-000000.log")
    File.write!(older, "older\n")
    File.touch!(older, System.os_time(:second) - 600)

    newer = Path.join(log_dir, "prompt-11-20260101-001000.log")
    File.write!(newer, "newer\n")

    assert {:ok, sample} = Watch.sample(root)
    assert sample.prompt == "11"
  end

  test "format_line emits the documented one-line shape" do
    line =
      Watch.format_line(%{
        timestamp: "16:57Z",
        runner: :up,
        pid: 1234,
        prompt: "11",
        quiet_minutes: 0,
        repos: 3,
        dirty: 0,
        commits: 27
      })

    assert line == "WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27"
  end

  test "format_line degrades honestly when a fact is unavailable" do
    line =
      Watch.format_line(%{
        timestamp: "16:57Z",
        runner: :down,
        pid: nil,
        prompt: nil,
        quiet_minutes: nil,
        repos: 0,
        dirty: 0,
        commits: 0
      })

    assert line == "WATCH 16:57Z runner=DOWN prompt=none quiet=?min repos=0 dirty=0 commits=0"
  end

  test "watch --once prints one line and returns", %{root: root} do
    output = capture_io(fn -> assert :ok = CLI.main(["watch", root, "--once"]) end)

    assert output =~ ~r/^WATCH \d\d:\d\dZ runner=DOWN prompt=none /
    assert String.trim(output) |> String.split("\n") |> length() == 1
  end

  test "watch --once --json prints one machine-readable sample", %{root: root} do
    output = capture_io(fn -> assert :ok = CLI.main(["watch", root, "--once", "--json"]) end)

    sample = Jason.decode!(output)

    assert sample["runner"] == "down"
    assert sample["repos"] == 1
    assert sample["packet"] == "watch-packet"
  end

  test "watch is listed in the help output" do
    output = capture_io(fn -> assert :ok = CLI.main(["help"]) end)

    assert output =~ "prompt_runner watch"
  end

  test "watch reports an error for a directory that is not a packet" do
    dir = FSHelpers.tmp_dir("prompt_runner_watch_not_a_packet")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, _reason} = Watch.sample(dir)
  end
end
