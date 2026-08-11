defmodule PromptRunner.ControlLiveRunTest do
  @moduledoc """
  The control plane against a run that is actually running.

  The unit tests drive `Plane` directly; these drive the whole chain — the
  runner opens the plane, a *separate* caller writes a request through
  `PromptRunner.Control`, and the render loop consumes it at an event boundary.
  """

  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Control
  alias PromptRunner.Control.Snapshot
  alias PromptRunner.Profile
  alias PromptRunner.Runner
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_control_live_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    packet_root = FSHelpers.tmp_dir("prompt_runner_control_live_packet")
    repo = FSHelpers.git_repo!("prompt_runner_control_live_repo")
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "control-live"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    log_mode: "compact"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Control live packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Step 01"
    targets:
      - "app"
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

    {:ok, packet_root: packet_root}
  end

  # The stream calls `during` between the two halves, which is the only place a
  # test can stand in for "a second terminal, while the run is in flight".
  defp expect_stream(events, during) do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      stream =
        Stream.flat_map(events, fn
          :interject ->
            during.()
            []

          event ->
            [event]
        end)

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)
  end

  defp run(packet_root) do
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    ExUnit.CaptureIO.capture_io(fn ->
      send(self(), {:result, Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])})
    end)
  end

  test "a second caller reads the run's header without disturbing it", %{
    packet_root: packet_root
  } do
    test_pid = self()

    expect_stream(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        %{type: :tool_call_started, data: %{tool_name: "Bash", tool_call_id: "t1"}},
        %{type: :token_usage_updated, data: %{input_tokens: 120, output_tokens: 34}},
        :interject,
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ],
      fn ->
        {:ok, run_ref} = Control.current_run(packet_root)
        {:ok, snapshot} = Control.snapshot(run_ref)
        send(test_pid, {:snapshot, snapshot})
      end
    )

    output = run(packet_root)
    assert_received {:result, :ok}
    assert_received {:snapshot, %Snapshot{} = snapshot}

    assert snapshot.status == :running
    assert snapshot.prompt_id == "01"
    assert snapshot.prompt_name == "Step 01"
    assert snapshot.attempt == 1
    assert snapshot.mode == :run
    assert snapshot.provider == :simulated
    assert snapshot.tool_count == 1
    assert snapshot.input_tokens == 120
    assert snapshot.output_tokens == 34
    assert snapshot.elapsed_ms >= 0

    # Reading a snapshot must leave no trace in the run's own output.
    refute output =~ "snapshot"
  end

  test "control view changes rendering within one event boundary", %{packet_root: packet_root} do
    expect_stream(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :tool_call_started, data: %{tool_name: "Bash", tool_call_id: "t1"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ],
      fn ->
        {:ok, run_ref} = Control.current_run(packet_root)
        :ok = Control.set_view(run_ref, %{log_mode: "verbose"}, author: "ada")
      end
    )

    output = run(packet_root)
    assert_received {:result, :ok}

    # Compact renders `t+Bash`; verbose renders `[run_completed]`. The request
    # was written between those two events and applied at the boundary after
    # the first of them, so the output carries one rendering of each — which is
    # what "within one event boundary" means, and is also the proof that
    # nothing was re-rendered retroactively.
    assert output =~ "t+Bash"
    assert output =~ "[run_completed]"

    {:ok, run_ref} = Control.current_run(packet_root)
    assert {:ok, [entry]} = Control.log(run_ref)
    assert entry.command == "set_view"
    assert entry.outcome == :applied
    assert entry.author == "ada"
    assert entry.prompt_id == "01"
    assert entry.attempt == 1

    assert {:ok, snapshot} = Control.snapshot(run_ref)
    assert snapshot.view.log_mode == :verbose
    assert snapshot.status == :completed
  end

  test "a malformed request is logged and removed, and the run continues", %{
    packet_root: packet_root
  } do
    expect_stream(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ],
      fn ->
        dir = Path.join([packet_root, ".prompt_runner", "control", "requests"])
        File.write!(Path.join(dir, "20260810-000000-000000-1.json"), "{ not json")
      end
    )

    run(packet_root)
    assert_received {:result, :ok}

    {:ok, run_ref} = Control.current_run(packet_root)
    assert {:ok, [entry]} = Control.log(run_ref)
    assert entry.outcome == :rejected

    assert File.ls!(Path.join([packet_root, ".prompt_runner", "control", "requests"])) == []
  end

  test "the snapshot records how the run ended when a prompt fails", %{packet_root: packet_root} do
    expect(PromptRunner.LLMMock, :start_stream, fn _llm, _prompt ->
      {:error, :boom}
    end)

    run(packet_root)
    assert_received {:result, {:error, _reason}}

    {:ok, run_ref} = Control.current_run(packet_root)
    assert {:ok, %Snapshot{status: :failed}} = Control.snapshot(run_ref)
  end

  test "a subscriber sees the run's events through Control alone", %{packet_root: packet_root} do
    test_pid = self()

    expect_stream(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ],
      fn ->
        {:ok, run_ref} = Control.current_run(packet_root)
        {:ok, ref} = Control.subscribe(run_ref, test_pid, interval_ms: 20)
        send(test_pid, {:subscribed, ref})
      end
    )

    run(packet_root)
    assert_received {:result, :ok}
    assert_received {:subscribed, ref}

    assert_receive {:prompt_runner_event, ^ref, %{"type" => "run_started"}}, 2_000
    assert_receive {:prompt_runner_event, ^ref, %{"type" => "message_streamed"}}, 2_000
    assert_receive {:prompt_runner_control, ^ref, {:run_finished, :completed}}, 2_000
  end

  test "an in-memory run writes no control directory at all", %{packet_root: packet_root} do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      stream = [%{type: :run_completed, data: %{stop_reason: "end_turn"}}]
      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    {:ok, plan} = PromptRunner.plan(packet_root, runtime_store: :memory, committer: :noop)

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])
    end)

    refute File.exists?(Path.join([packet_root, ".prompt_runner", "control"]))
  end
end
