defmodule PromptRunner.ControlAmendmentTest do
  @moduledoc """
  Changing what "done" means, on the record.

  Amendment is the one capability in this program that can make a completed
  prompt mean something other than what the packet says. Every test here is
  about whether that stays visible.
  """

  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Control
  alias PromptRunner.Control.Amendment
  alias PromptRunner.Control.Plane
  alias PromptRunner.Profile
  alias PromptRunner.Runner
  alias PromptRunner.Runtime
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_amend_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    packet_root = FSHelpers.tmp_dir("prompt_runner_amend_packet")
    repo = FSHelpers.git_repo!("prompt_runner_amend_repo")
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "amend"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Amend packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Step 01"
    targets:
      - "app"
    recovery:
      repair:
        enabled: false
    verify:
      files_exist:
        - "README.md"
    ---
    # Step 01
    """)

    on_exit(fn ->
      Application.delete_env(:prompt_runner, :llm_module)

      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    {:ok, packet_root: packet_root, repo: repo}
  end

  defp open_run(packet_root) do
    Plane.open(packet_root, packet: "amend", max_steers: 2)
    {:ok, run_ref} = Control.current_run(packet_root)
    run_ref
  end

  defp run(packet_root) do
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    ExUnit.CaptureIO.capture_io(fn ->
      send(self(), {:result, Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])})
    end)
  end

  defp expect_session do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      stream = [%{type: :run_completed, data: %{stop_reason: "end_turn"}}]
      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)
  end

  describe "governance" do
    test "an amendment with no reason is refused, not defaulted", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      assert {:error, :reason_required} =
               Control.amend(run_ref, "01", clause: "files_exist", entries: ["lib/foo.ex"])

      assert Amendment.read(packet_root, "01") == []
    end

    test "relax without confirmation refuses and explains", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      assert {:error, :confirmation_required} =
               Control.relax(run_ref, "01", clause: "files_exist", reason: "was wrong")

      assert Amendment.read(packet_root, "01") == []
    end

    test "relax with confirmation is allowed and recorded as the risky direction", %{
      packet_root: packet_root
    } do
      run_ref = open_run(packet_root)

      assert :ok =
               Control.relax(run_ref, "01",
                 clause: "files_exist",
                 reason: "the requirement was wrong",
                 confirm: true
               )

      assert [record] = Amendment.read(packet_root, "01")
      assert record["direction"] == "relax"
      assert record["operation"] == "drop"
      assert record["reason"] == "the requirement was wrong"
    end

    test "a clause the verifier does not evaluate is refused", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      assert {:error, {:unknown_clause, "file_exists"}} =
               Control.amend(run_ref, "01",
                 clause: "file_exists",
                 entries: ["a"],
                 reason: "typo"
               )
    end
  end

  describe "timing is part of the meaning" do
    test "an amendment after a verify pass says so, rather than claiming a failure", %{
      packet_root: packet_root
    } do
      expect_session()
      run(packet_root)
      assert_received {:result, :ok}

      {:ok, run_ref} = Control.current_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/foo.ex"],
          reason: "scope grew"
        )

      assert [record] = Amendment.read(packet_root, "01")
      assert record["phase"] == "post_success"
    end

    test "an amendment before any verify attempt is pre_verify", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/foo.ex"],
          reason: "the work needs a module the packet author did not anticipate"
        )

      assert [record] = Amendment.read(packet_root, "01")
      assert record["phase"] == "pre_verify"
    end

    test "the same amendment after a verify failure is post_failure", %{
      packet_root: packet_root
    } do
      # A real run, a real verify attempt, a real failure.
      File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
      ---
      id: "01"
      phase: 1
      name: "Step 01"
      targets:
        - "app"
      recovery:
        repair:
          enabled: false
      verify:
        files_exist:
          - "never.txt"
      ---
      # Step 01
      """)

      expect_session()
      run(packet_root)
      assert_received {:result, {:error, {:verification_failed, _report}}}

      {:ok, run_ref} = Control.current_run(packet_root)

      :ok =
        Control.relax(run_ref, "01",
          clause: "files_exist",
          reason: "decided this was not needed after all",
          confirm: true
        )

      assert [record] = Amendment.read(packet_root, "01")

      # This is the move pre-registration exists to prevent. It is not
      # forbidden — but it is never quiet.
      assert record["phase"] == "post_failure"
    end
  end

  describe "what gets enforced" do
    test "an added requirement is enforced", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/never_written.ex"],
          reason: "the work needs this module"
        )

      expect_session()
      run(packet_root)

      # README.md exists, so the packet contract alone would have passed.
      assert_received {:result, {:error, {:verification_failed, report}}}
      assert [failure] = report.failures
      assert failure.path == "lib/never_written.ex"
    end

    test "a dropped requirement is no longer enforced", %{packet_root: packet_root} do
      File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
      ---
      id: "01"
      phase: 1
      name: "Step 01"
      targets:
        - "app"
      recovery:
        repair:
          enabled: false
      verify:
        files_exist:
          - "never.txt"
      ---
      # Step 01
      """)

      run_ref = open_run(packet_root)

      :ok =
        Control.relax(run_ref, "01",
          clause: "files_exist",
          reason: "the requirement was wrong",
          confirm: true
        )

      expect_session()
      run(packet_root)
      assert_received {:result, :ok}
    end

    test "a re-run from clean state uses the packet's contract, not the amended one", %{
      packet_root: packet_root
    } do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/never_written.ex"],
          reason: "run-local scope correction"
        )

      {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)
      prompt = Enum.find(plan.prompts, &(&1.num == "01"))

      # With the amendment log present, the extra requirement is enforced.
      assert Verifier.enforced_contract(plan, prompt)["files_exist"] == [
               "README.md",
               "lib/never_written.ex"
             ]

      # Clean state — the packet file is untouched and is the whole answer.
      File.rm_rf!(Amendment.dir(packet_root))
      assert Verifier.enforced_contract(plan, prompt)["files_exist"] == ["README.md"]
      assert prompt.verify["files_exist"] == ["README.md"]
    end

    test "--persist writes the change into the packet file itself", %{packet_root: packet_root} do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/foo.ex"],
          reason: "the work needs this module",
          persist: true
        )

      # Even with the amendment log gone, the packet now says it.
      File.rm_rf!(Amendment.dir(packet_root))

      {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)
      prompt = Enum.find(plan.prompts, &(&1.num == "01"))

      assert "lib/foo.ex" in prompt.verify["files_exist"]
    end
  end

  describe "the audit" do
    test "contract/2 shows packet versus enforced as a readable diff", %{
      packet_root: packet_root
    } do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["lib/foo.ex"],
          reason: "needed"
        )

      :ok =
        Control.relax(run_ref, "01",
          clause: "commands",
          reason: "there were none anyway",
          confirm: true
        )

      assert {:ok, report} = Control.contract(packet_root, "01")

      assert report.packet["files_exist"] == ["README.md"]
      assert report.enforced["files_exist"] == ["README.md", "lib/foo.ex"]

      assert {:same, "files_exist", "README.md"} in report.diff
      assert {:added, "files_exist", "lib/foo.ex"} in report.diff

      assert length(report.amendments) == 2
    end

    test "a prompt completed under an amended contract says so in its state", %{
      packet_root: packet_root
    } do
      run_ref = open_run(packet_root)

      :ok =
        Control.amend(run_ref, "01",
          clause: "files_exist",
          entries: ["README.md"],
          reason: "belt and braces"
        )

      expect_session()
      run(packet_root)
      assert_received {:result, :ok}

      {:ok, state} = Runtime.prompt_state(packet_root, "01")

      assert state["status"] == "completed"
      assert state["amended"] == true
      assert state["amendments_file"] =~ "amendments/01.jsonl"
      assert [record] = state["amendments"]
      assert record["reason"] == "belt and braces"
      assert record["phase"] == "pre_verify"
    end

    test "an unamended prompt is recorded as unamended", %{packet_root: packet_root} do
      expect_session()
      run(packet_root)
      assert_received {:result, :ok}

      {:ok, state} = Runtime.prompt_state(packet_root, "01")
      assert state["amended"] == false
      refute Map.has_key?(state, "amendments_file")
    end
  end
end
