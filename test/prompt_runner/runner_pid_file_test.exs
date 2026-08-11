defmodule PromptRunner.RunnerPidFileTest do
  @moduledoc """
  The runner writes `.prompt_runner/run.pid` for the duration of a run.

  Liveness has to be checkable by something outside the run. A pgrep pattern is
  not that check: it matches any process whose command line contains the
  string, including the supervisor's own shell, which reports a healthy run
  forever. A pid file plus a signal-zero probe cannot self-match.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.Paths
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  # Verification failures in the second test would otherwise walk the whole
  # retry/repair ladder, which is not what these tests are about.
  @no_recovery """
  recovery:
    resume_attempts: 0
    retry:
      max_attempts: 0
      base_delay_ms: 0
      max_delay_ms: 0
      class_attempts:
        unknown: 0
    repair:
      enabled: false
      max_attempts: 0
  """

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_pid_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_pid_repo")

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
    end)

    {:ok, repo: repo}
  end

  defp packet!(repo, expected_file) do
    root =
      FSHelpers.packet!(
        "prompt_runner_pid_packet",
        """
        ---
        name: "pid-packet"
        profile: "simulated-default"
        provider: "simulated"
        model: "simulated-demo"
        #{@no_recovery}repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Pid Packet
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
               - "#{expected_file}"
           ---
           # Noop

           ## Mission

           Do nothing.
           """}
        ]
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "the pid file holds the OS pid while a run is in flight and is removed after", %{
    repo: repo
  } do
    root = packet!(repo, "README.md")
    pid_path = root |> Paths.state_dir() |> Paths.pid_file()
    test_pid = self()

    capture_io(fn ->
      assert {:ok, _run} =
               PromptRunner.run(root,
                 interface: :cli,
                 no_commit: true,
                 on_prompt_started: fn _event ->
                   send(test_pid, {:pid_file, File.read(pid_path)})
                 end
               )
    end)

    assert_received {:pid_file, {:ok, contents}}
    pid = System.pid()
    assert [^pid, start_time] = String.split(contents)
    assert start_time =~ ~r/^\d+$/

    refute File.exists?(pid_path)
  end

  test "the pid file is removed even when the run fails", %{repo: repo} do
    root = packet!(repo, "NEVER_WRITTEN.md")
    pid_path = root |> Paths.state_dir() |> Paths.pid_file()

    capture_io(fn ->
      assert {:error, _reason} = PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    refute File.exists?(pid_path)
  end

  test "a second run cannot overwrite the active run's pid file", %{repo: repo} do
    root = packet!(repo, "README.md")
    pid_path = root |> Paths.state_dir() |> Paths.pid_file()
    test_pid = self()

    capture_io(fn ->
      assert {:ok, _run} =
               PromptRunner.run(root,
                 interface: :cli,
                 no_commit: true,
                 on_prompt_started: fn _event ->
                   before = File.read!(pid_path)

                   assert {:error, {:run_already_active, ^pid_path, _pid}} =
                            PromptRunner.run(root, interface: :cli, no_commit: true)

                   send(test_pid, {:lock_unchanged, before == File.read!(pid_path)})
                 end
               )
    end)

    assert_received {:lock_unchanged, true}
    refute File.exists?(pid_path)
  end
end
