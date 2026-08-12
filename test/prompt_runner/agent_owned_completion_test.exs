defmodule PromptRunner.AgentOwnedCompletionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias PromptRunner.CompletionPolicy
  alias PromptRunner.Profile
  alias PromptRunner.Runner
  alias PromptRunner.Runtime
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_agent_owned_home")
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

  defp packet!(opts \\ []) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_agent_owned_packet")
    repo = FSHelpers.git_repo!("prompt_runner_agent_owned_repo")
    execution = Keyword.get(opts, :execution, agent_owned_execution())
    verify = Keyword.get(opts, :verify, structural_verify())
    body = Keyword.get(opts, :body, "# Step 01\n\nComplete the evidence.\n")

    on_exit(fn ->
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "agent-owned-packet"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    #{execution}repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Agent-owned packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Step 01"
    targets:
      - "app"
    #{verify}---
    #{body}
    """)

    {packet_root, repo}
  end

  defp agent_owned_execution do
    """
    execution:
      completion: "agent_owned"
      incomplete: "repeat"
    """
  end

  defp structural_verify do
    """
    verify:
      files_exist:
        - "evidence.txt"
      contains:
        - path: "evidence.txt"
          text: "complete"
    """
  end

  defp success_stream(llm) do
    stream = [
      %{type: :run_started, data: %{model: llm.model}},
      %{type: :run_completed, data: %{stop_reason: "end_turn"}}
    ]

    {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
  end

  defp run_remaining(plan) do
    capture_io(fn ->
      send(
        self(),
        {:runner_result,
         Runner.execute_plan(plan, [run: true, remaining: true, no_commit: true], [])}
      )
    end)

    assert_receive {:runner_result, result}
    result
  end

  test "normalizes the opt-in policy and preserves the verifier-owned default" do
    assert {:ok, %{completion: :verifier_owned, incomplete: :fail}} =
             CompletionPolicy.from_options(%{})

    assert {:ok, %{completion: :agent_owned, incomplete: :repeat}} =
             CompletionPolicy.from_options(%{
               "execution" => %{
                 "completion" => "agent_owned",
                 "incomplete" => "repeat"
               }
             })
  end

  test "rejects invalid execution values" do
    assert {:error, {:agent_owned_requires, %{incomplete: :repeat}}} =
             CompletionPolicy.from_options(%{
               execution: %{completion: :agent_owned}
             })

    assert {:error, {:invalid_completion, "imaginary"}} =
             CompletionPolicy.from_options(%{
               execution: %{completion: "imaginary", incomplete: "repeat"}
             })
  end

  test "agent-owned plans reject executable verifier commands" do
    verify = """
    verify:
      files_exist:
        - "evidence.txt"
      commands:
        - "false"
    """

    {packet_root, _repo} = packet!(verify: verify)

    assert {:error, {:invalid_agent_owned_prompts, findings}} =
             PromptRunner.plan(packet_root, interface: :cli)

    assert %{prompt_id: "01", kind: :verify_commands_not_allowed} in findings
  end

  test "agent-owned plans reject clean-only completion" do
    verify = """
    verify:
      repos_clean:
        - repo: "app"
    """

    {packet_root, _repo} = packet!(verify: verify)

    assert {:error, {:invalid_agent_owned_prompts, findings}} =
             PromptRunner.plan(packet_root, interface: :cli)

    assert %{prompt_id: "01", kind: :prompt_specific_structural_evidence_required} in findings
  end

  test "structural verification does not execute commands" do
    verify = """
    verify:
      files_exist:
        - "evidence.txt"
      commands:
        - "printf ran > command-ran.txt; exit 9"
    """

    {packet_root, repo} = packet!(execution: "", verify: verify)
    File.write!(Path.join(repo, "evidence.txt"), "complete\n")
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)
    [prompt] = plan.prompts

    assert %{pass?: true} = Verifier.verify_prompt(plan, prompt, executable: false)
    refute File.exists?(Path.join(repo, "command-ran.txt"))

    assert %{pass?: false} = Verifier.verify_prompt(plan, prompt)
    assert File.read!(Path.join(repo, "command-ran.txt")) == "ran"
  end

  test "an incomplete normal return repeats the same prompt in a fresh session" do
    {packet_root, repo} = packet!()
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    expect(PromptRunner.LLMMock, :start_stream, fn llm, prompt ->
      refute prompt =~ "Agent-Owned Completion — Fresh Session"
      success_stream(llm)
    end)

    expect(PromptRunner.LLMMock, :start_stream, fn llm, prompt ->
      assert prompt =~ "Agent-Owned Completion — Fresh Session 2"
      assert prompt =~ "evidence.txt"
      File.write!(Path.join(repo, "evidence.txt"), "complete\n")
      success_stream(llm)
    end)

    assert run_remaining(plan) == :ok

    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    assert state["status"] == "completed"
    assert Enum.map(state["attempts"], & &1["mode"]) == ["run", "agent_owned_repeat"]
    assert Enum.map(state["attempts"], & &1["status"]) == ["incomplete", "completed"]
  end

  test "verify-first does not skip an unrecorded agent-owned prompt with stale evidence" do
    {packet_root, repo} = packet!()
    File.write!(Path.join(repo, "evidence.txt"), "complete\n")
    {_output, 0} = System.cmd("git", ["add", "evidence.txt"], cd: repo, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "stale evidence"], cd: repo, stderr_to_stdout: true)

    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt -> success_stream(llm) end)

    assert run_remaining(plan) == :ok
    {:ok, state} = Runtime.prompt_state(packet_root, "01")
    assert state["source"] != "preflight_verify"
    assert length(state["attempts"]) == 1
  end

  test "completed state remains excluded from a later remaining selection" do
    {packet_root, repo} = packet!()
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      File.write!(Path.join(repo, "evidence.txt"), "complete\n")
      success_stream(llm)
    end)

    assert run_remaining(plan) == :ok
    assert Runner.select_targets(plan, [remaining: true], []) == {:ok, []}
    assert run_remaining(plan) == :ok
  end

  test "a non-retryable provider start failure remains terminal" do
    {packet_root, _repo} = packet!()
    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)

    expect(PromptRunner.LLMMock, :start_stream, fn _llm, _prompt ->
      {:error, %{message: "authentication denied", retryable?: false}}
    end)

    assert {:error, {:start_failed, _reason}} = run_remaining(plan)
  end
end
