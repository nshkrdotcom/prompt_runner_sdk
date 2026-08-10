defmodule PromptRunner.VerificationFailureTest do
  @moduledoc """
  A prompt that cannot satisfy its contract must fail, in bounded time.

  Regression coverage for an unbounded repair loop.
  `RecoveryPolicy.final_action/5` returns `{:verification_failed, ...}` when
  repair is *not* available — disabled, out of attempts, or the attempt was
  itself a repair. The runner routed that outcome through the same function as
  `{:repair, ...}`, which returns `{:repair, ...}`, so the outcome handler
  started another repair attempt. Every subsequent attempt ran in `:repair`
  mode, took the same branch, and started another one. An unattended run
  re-invoked the provider forever, and the attempt list in `state.json` grew
  without bound.

  These tests are timed: a regression hangs rather than asserting falsely, so
  the timeout is the assertion.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  @moduletag timeout: 60_000

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_verifail_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_verifail_repo")

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
    end)

    {:ok, repo: repo}
  end

  defp packet!(repo, recovery) do
    root =
      FSHelpers.packet!(
        "prompt_runner_verifail_packet",
        """
        ---
        name: "verifail"
        profile: "simulated-default"
        provider: "simulated"
        model: "simulated-demo"
        #{recovery}repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Verification Failure Packet
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
               - "NEVER_WRITTEN.md"
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

  defp attempt_modes(root) do
    {:ok, status} = PromptRunner.status(root)

    status
    |> Map.get("prompts", %{})
    |> Map.get("01", %{})
    |> Map.get("attempts", [])
    |> Enum.map(& &1["mode"])
  end

  test "an unsatisfiable contract fails after the configured repair budget", %{repo: repo} do
    root = packet!(repo, "")

    output =
      capture_io(fn ->
        assert {:error, {:verification_failed, _report}} =
                 PromptRunner.run(root, interface: :cli, no_commit: true)
      end)

    modes = attempt_modes(root)

    # The default policy allows two repairs. One initial run plus at most that
    # many repairs, and then the run stops.
    assert "run" in modes
    assert Enum.count(modes, &(&1 == "repair")) <= 2
    assert length(modes) <= 3

    assert output =~ "Verification failed for prompt 01"
  end

  test "an unsatisfiable contract fails immediately when repair is disabled", %{repo: repo} do
    recovery = """
    recovery:
      repair:
        enabled: false
    """

    root = packet!(repo, recovery)

    capture_io(fn ->
      assert {:error, {:verification_failed, _report}} =
               PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    assert attempt_modes(root) == ["run"]
  end

  test "the reported error names the failing items rather than dumping the report", %{repo: repo} do
    recovery = """
    recovery:
      repair:
        enabled: false
    """

    root = packet!(repo, recovery)

    output =
      capture_io(fn ->
        assert {:error, _reason} = PromptRunner.run(root, interface: :cli, no_commit: true)
      end)

    assert output =~ "ERROR: verification failed: file_exists NEVER_WRITTEN.md: missing"
  end
end
