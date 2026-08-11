defmodule PromptRunner.Test.FailingCommitter do
  @behaviour PromptRunner.Committer

  @impl true
  def commit(_plan, _prompt, _llm, _opts), do: {:error, :deliberate_failure}
end

defmodule PromptRunner.RunnerPreflightVerifyTest do
  @moduledoc """
  Evaluating the contract before spending a provider session, and halting when
  the contract cannot be evaluated at all.

  Prompt 01 of a live packet was complete and pushed. Its contract could not
  execute, so it was re-run as a repair — seventy minutes of provider time to
  re-derive work that was already on the branch. Had the contract been checked
  first, the prompt would have been marked complete in about forty seconds.
  """

  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Profile
  alias PromptRunner.Progress
  alias PromptRunner.Runner
  alias PromptRunner.Runtime
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_preflight_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    on_exit(fn ->
      Application.delete_env(:prompt_runner, :llm_module)

      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  defp packet!(prompt_front_matter) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_preflight_packet")
    repo = FSHelpers.git_repo!("prompt_runner_preflight_repo")

    on_exit(fn ->
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "preflight-packet"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Preflight packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Step 01"
    targets:
      - "app"
    #{prompt_front_matter}
    ---
    # Step 01
    """)

    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)
    {plan, packet_root, repo}
  end

  defp run_quiet(fun) when is_function(fun, 0) do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        send(self(), {:runner_result, fun.()})
      end)

    assert_receive {:runner_result, result}
    {result, output}
  end

  defp expect_one_session do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      stream = [
        %{type: :run_started, data: %{model: llm.model}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)
  end

  defp prompt_state(packet_root) do
    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    state
  end

  describe "pre-flight verification" do
    test "a prompt whose contract already passes completes with no provider session" do
      {plan, packet_root, _repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      {result, output} =
        run_quiet(fn -> Runner.execute_plan(plan, [run: true, remaining: true], []) end)

      assert result == :ok
      assert output =~ "no session was run"

      assert Progress.statuses(plan)["01"].status == "completed"

      state = prompt_state(packet_root)
      assert state["status"] == "completed"
      assert state["source"] == "preflight_verify"
      assert state["session_ran"] == false
      assert state["attempts"] in [nil, []]
    end

    test "a passing but uncommitted evidence file still runs a session" do
      {plan, _packet_root, repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      File.write!(Path.join(repo, "README.md"), "finished but not committed\n")
      expect_one_session()

      {result, output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, remaining: true, no_commit: true], [])
        end)

      assert result == :ok
      refute output =~ "no session was run"
    end

    test "a prompt whose contract fails still runs a session" do
      # Repair off, so the assertion is about how many sessions pre-flight
      # allowed rather than about how many the repair policy adds afterwards.
      {plan, _packet_root, _repo} =
        packet!("""
        recovery:
          repair:
            enabled: false
        verify:
          files_exist:
            - "never.txt"
        """)

      expect_one_session()

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, remaining: true, no_commit: true], [])
        end)

      assert {:error, {:verification_failed, _report}} = result
    end

    # A contract with nothing evaluable in it passes vacuously. Marking a prompt
    # complete on that would report work that nothing ever checked.
    test "a prompt with no verify contract is never completed by pre-flight" do
      {plan, _packet_root, _repo} = packet!("")

      expect_one_session()

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, remaining: true, no_commit: true], [])
        end)

      assert result == :ok
    end

    # `changed_paths_only` reads `git status --porcelain`, so a clean tree
    # satisfies it — including the clean tree that exists before any session has
    # run at all.
    test "a contract containing changed_paths_only is not pre-flighted" do
      {plan, _packet_root, _repo} =
        packet!("""
        verify:
          changed_paths_only:
            - "lib/thing.ex"
        """)

      expect_one_session()

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, remaining: true, no_commit: true], [])
        end)

      assert result == :ok
    end

    test "naming a prompt explicitly runs it even when its contract passes" do
      {plan, _packet_root, _repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      expect_one_session()

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])
        end)

      assert result == :ok
    end

    test "--verify-first turns pre-flight on for an explicitly named prompt" do
      {plan, packet_root, _repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, verify_first: true, no_commit: true], ["01"])
        end)

      assert result == :ok
      assert prompt_state(packet_root)["session_ran"] == false
    end

    test "--no-verify-first turns pre-flight off for --remaining" do
      {plan, _packet_root, _repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      expect_one_session()

      {result, _output} =
        run_quiet(fn ->
          Runner.execute_plan(
            plan,
            [run: true, remaining: true, verify_first: false, no_commit: true],
            []
          )
        end)

      assert result == :ok
    end
  end

  describe "commit completion" do
    test "a failed committer cannot mark a verified prompt complete" do
      {plan, packet_root, _repo} =
        packet!("""
        verify:
          files_exist:
            - "README.md"
        """)

      plan = %{plan | committer: {PromptRunner.Test.FailingCommitter, []}}
      expect_one_session()

      {result, _output} =
        run_quiet(fn -> Runner.execute_plan(plan, [run: true], ["01"]) end)

      assert {:error, {:commit_failed, {:error, :deliberate_failure}}} = result
      assert Progress.statuses(plan)["01"].status == "failed"
      assert prompt_state(packet_root)["status"] == "commit_failed"
    end
  end

  describe "verifier faults halt the run" do
    test "a contract naming a missing script halts before any session starts" do
      {plan, packet_root, _repo} =
        packet!("""
        verify:
          commands:
            - "./bin/check_doc.sh"
        """)

      {result, output} =
        run_quiet(fn -> Runner.execute_plan(plan, [run: true, remaining: true], []) end)

      assert {:error, {:verifier_fault, [fault]}} = result
      assert fault.exit_code == 127
      assert output =~ "Verifier could not run"
      assert output =~ "check_doc.sh"

      state = prompt_state(packet_root)
      assert state["status"] == "verifier_fault"
      assert state["stage"] == "preflight"
    end

    test "a fault after a session halts and spends no repair attempt" do
      {plan, packet_root, _repo} =
        packet!("""
        verify:
          commands:
            - "./bin/check_doc.sh"
        """)

      expect_one_session()

      {result, output} =
        run_quiet(fn ->
          Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])
        end)

      assert {:error, {:verifier_fault, [_fault]}} = result
      assert output =~ "No repair attempt was spent"

      state = prompt_state(packet_root)
      assert state["status"] == "verifier_fault"
      assert state["stage"] == "post_session"

      modes = Enum.map(state["attempts"] || [], & &1["mode"])
      assert modes == ["run"]
      refute "repair" in modes
    end

    test "a fault does not mark the prompt failed in the progress store" do
      {plan, _packet_root, _repo} =
        packet!("""
        verify:
          commands:
            - "./bin/check_doc.sh"
        """)

      {_result, _output} =
        run_quiet(fn -> Runner.execute_plan(plan, [run: true, remaining: true], []) end)

      assert Progress.statuses(plan)["01"] == nil
    end
  end
end
