defmodule PromptRunner.ControlSteeringTest do
  @moduledoc """
  Saying something to an agent that is already working.

  Steering changes *how* the agent works toward an unchanged definition of
  done. The verify contract is untouched — which is what makes it safe to allow
  freely, and what makes amendment a different verb.
  """

  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Control
  alias PromptRunner.Control.Interventions
  alias PromptRunner.Control.Plane
  alias PromptRunner.Profile
  alias PromptRunner.Runner
  alias PromptRunner.Runtime
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_steer_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    packet_root = FSHelpers.tmp_dir("prompt_runner_steer_packet")
    repo = FSHelpers.git_repo!("prompt_runner_steer_repo")
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "steer"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    recovery:
      max_steers: 2
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Steer packet
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

  # The mock stands in for the two lanes: `accepts_input?` is false for
  # `:simulated`, so the runner takes the interrupt-and-resume path, and the
  # mock's `resume_stream` is where the steer text lands.
  defp expect_run(events, during, resume) do
    # `:simulated` closes stdin, so the runner takes the interrupt-and-resume
    # path and the steer text lands as the resume prompt.
    stub(PromptRunner.LLMMock, :steer, fn _llm, _meta, _text -> {:ok, :interrupted} end)

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

    if resume, do: expect_resume(resume)
  end

  defp expect_resume(resume) do
    expect(PromptRunner.LLMMock, :resume_stream, fn llm, _meta, prompt ->
      resume.(prompt)

      stream = [%{type: :run_completed, data: %{stop_reason: "end_turn"}}]
      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)
  end

  defp run(packet_root) do
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    ExUnit.CaptureIO.capture_io(fn ->
      send(self(), {:result, Runner.execute_plan(plan, [run: true, no_commit: true], ["01"])})
    end)
  end

  defp steer_from_elsewhere(packet_root, text, opts \\ []) do
    {:ok, run_ref} = Control.current_run(packet_root)
    :ok = Control.steer(run_ref, text, opts)
  end

  test "a steer interrupts the turn and resumes the same thread with the text", %{
    packet_root: packet_root
  } do
    test_pid = self()

    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn ->
        steer_from_elsewhere(packet_root, "check dependency_sources.exs first", author: "ada")
      end,
      fn prompt -> send(test_pid, {:resumed_with, prompt}) end
    )

    output = run(packet_root)
    assert_received {:result, :ok}
    assert_received {:resumed_with, "check dependency_sources.exs first"}

    assert output =~ "interrupting to steer"
    assert output =~ "Resuming the provider thread with the steer"
  end

  test "the steer is recorded on the control log with its attempt", %{packet_root: packet_root} do
    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn -> steer_from_elsewhere(packet_root, "slow down", author: "ada") end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, :ok}

    {:ok, run_ref} = Control.current_run(packet_root)
    assert {:ok, entries} = Control.log(run_ref)
    assert [entry] = Enum.filter(entries, &(&1.command == "steer"))
    assert entry.outcome == :applied
    assert entry.author == "ada"
    assert entry.prompt_id == "01"
    assert entry.attempt == 1
    assert entry.params["delivery"] == "interrupt_and_resume"
  end

  test "the steer is an artifact in the packet, not only in run state", %{
    packet_root: packet_root
  } do
    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn -> steer_from_elsewhere(packet_root, "use the shared helper", author: "ada") end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, :ok}

    assert [record] = Interventions.read(packet_root, "01")
    assert record["text"] == "use the shared helper"
    assert record["prompt"] == "01"
    assert record["attempt"] == 1
    assert record["author"] == "ada"
    assert record["lane"] == "simulated"
    assert record["delivery"] == "interrupt_and_resume"
    assert record["at"] =~ ~r/^\d{4}-/

    # Committed with the work, so it lives under the packet rather than only in
    # the state file that a `rm -rf .prompt_runner` would take with it.
    assert File.exists?(Path.join([packet_root, ".prompt_runner", "interventions", "01.jsonl"]))
  end

  test "the prompt's result says it was steered", %{packet_root: packet_root} do
    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn -> steer_from_elsewhere(packet_root, "try the other approach") end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, :ok}

    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    assert state["status"] == "completed"
    assert state["steered"] == true
    assert state["steer_count"] == 1
    assert state["interventions_file"] =~ "interventions/01.jsonl"
  end

  test "an unsteered prompt is recorded as unsteered", %{packet_root: packet_root} do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      stream = [%{type: :run_completed, data: %{stop_reason: "end_turn"}}]
      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    run(packet_root)
    assert_received {:result, :ok}

    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    assert state["steered"] == false
    refute Map.has_key?(state, "steer_count")
  end

  test "a steer beyond max_steers is refused and logged, and the run continues", %{
    packet_root: packet_root
  } do
    # The packet allows two. The third is refused.
    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "one"}}
      ],
      fn ->
        {:ok, run_ref} = Control.current_run(packet_root)
        :ok = Control.steer(run_ref, "first", author: "ada")
      end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, :ok}

    # Drive the budget directly from here: three steers against a plane whose
    # budget is two.
    plane =
      Plane.open(packet_root, packet: "steer", max_steers: 2)
      |> Plane.prompt_started(%{num: "01", name: "Step 01"}, :run, 1, %{sdk: :simulated})

    {:ok, run_ref} = Control.current_run(packet_root)

    plane =
      Enum.reduce(1..3, plane, fn n, acc ->
        :ok = Control.steer(run_ref, "steer #{n}")
        {acc, commands} = Plane.boundary(acc)

        case commands do
          [{:steer, text, author}] ->
            Plane.steer_delivered(acc, text, author, :simulated, :interrupt_and_resume)

          [] ->
            acc
        end
      end)

    assert Plane.steer_count(plane) == 2

    {:ok, entries} = Control.log(run_ref)
    refusal = entries |> Enum.filter(&(&1.outcome == :rejected)) |> List.last()
    assert refusal.command == "steer"
    assert refusal.reason =~ "budget spent"
  end

  test "a steer while no session is live is refused with a clear reason", %{
    packet_root: packet_root
  } do
    plane = Plane.open(packet_root, packet: "steer", max_steers: 2)
    {:ok, run_ref} = Control.current_run(packet_root)

    :ok = Control.steer(run_ref, "hello?", author: "ada")
    {_plane, commands} = Plane.boundary(plane)

    assert commands == []
    assert {:ok, [entry]} = Control.log(run_ref)
    assert entry.outcome == :rejected
    assert entry.reason == "no prompt is running"
  end

  test "an empty steer is refused before it is ever written", %{packet_root: packet_root} do
    plane = Plane.open(packet_root, packet: "steer", max_steers: 2)
    {:ok, run_ref} = Control.current_run(packet_root)

    assert {:error, :empty_steer} = Control.steer(run_ref, "   ")
    assert {_plane, []} = Plane.boundary(plane)
    assert {:ok, []} = Control.log(run_ref)
  end

  test "steering does not change how many retry or repair attempts remain", %{
    packet_root: packet_root
  } do
    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn -> steer_from_elsewhere(packet_root, "different approach please") end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, :ok}

    {:ok, attempts} = Runtime.get_attempts(packet_root, "01")

    # One attempt, mode `run`. A steer is not an attempt to satisfy the
    # contract, so it neither consumes nor resets the attempt budgets.
    assert Enum.map(attempts, & &1["mode"]) == ["run"]
  end

  # A contract asserting content is not satisfied by a steer that dictated that
  # content. The verifier sees the workspace, not the conversation.
  test "a steer is not evidence", %{packet_root: packet_root} do
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
      contains:
        - path: "NOTES.md"
          text: "the sky is green"
    ---
    # Step 01
    """)

    expect_run(
      [
        %{type: :run_started, data: %{model: "simulated-demo"}},
        :interject,
        %{type: :message_streamed, data: %{delta: "working"}}
      ],
      fn -> steer_from_elsewhere(packet_root, "write 'the sky is green' into NOTES.md") end,
      fn _prompt -> :ok end
    )

    run(packet_root)
    assert_received {:result, {:error, {:verification_failed, report}}}

    assert [failure] = report.failures
    assert failure.path == "NOTES.md"

    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    assert state["status"] == "verification_failed"
    assert state["steered"] == true
  end
end
