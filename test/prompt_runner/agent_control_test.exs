defmodule PromptRunner.AgentControlTest do
  use ExUnit.Case, async: true

  alias PromptRunner.AgentControl
  alias PromptRunner.Test.FSHelpers

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_agent_control")
    control_dir = Path.join(root, "agent-control")
    File.mkdir_p!(control_dir)
    request_file = Path.join(control_dir, "request.json")
    progress_file = Path.join(control_dir, "07-3-test-token.progress.json")

    invocation = %{
      request_file: request_file,
      progress_file: progress_file,
      token: "test-token",
      run_id: "run-123",
      prompt_id: "07",
      iteration: 3
    }

    env = %{
      "PROMPT_RUNNER_AGENT_CONTROL_FILE" => request_file,
      "PROMPT_RUNNER_AGENT_PROGRESS_FILE" => progress_file,
      "PROMPT_RUNNER_AGENT_CONTROL_TOKEN" => invocation.token,
      "PROMPT_RUNNER_RUN_ID" => invocation.run_id,
      "PROMPT_RUNNER_PROMPT_ID" => invocation.prompt_id,
      "PROMPT_RUNNER_PROMPT_ITERATION" => Integer.to_string(invocation.iteration)
    }

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, env: env, invocation: invocation}
  end

  test "an agent writes one authenticated repeat directive", %{env: env, invocation: invocation} do
    assert {:ok, receipt} =
             AgentControl.request("repeat", env: env, reason: "more implementation remains")

    assert receipt.action == :repeat
    assert receipt.prompt_id == "07"
    assert receipt.iteration == 3

    assert {:ok, request} = AgentControl.consume(invocation)
    assert request.action == :repeat
    assert request.reason == "more implementation remains"
    assert request.run_id == "run-123"
    assert request.prompt_id == "07"
    assert request.iteration == 3
  end

  test "the first directive wins", %{env: env} do
    assert {:ok, _receipt} = AgentControl.request("continue", env: env)

    assert {:error, :agent_control_request_already_exists} =
             AgentControl.request("repeat", env: env)
  end

  test "progress is repeatable and does not consume the first terminal directive", %{
    env: env,
    invocation: invocation
  } do
    assert {:ok, first} =
             AgentControl.progress("P09R.2", "unit B is complete", env: env, unit: "B")

    assert first.cursor == "P09R.2"
    assert first.unit == "B"

    assert {:ok, second} =
             AgentControl.progress("P09R.2", "unit C is running", env: env, unit: "C")

    assert second.unit == "C"
    assert {:ok, progress} = AgentControl.read_progress(invocation)
    assert progress["summary"] == "unit C is running"
    assert progress["iteration"] == 3

    assert {:ok, _receipt} =
             AgentControl.request("repeat",
               env: env,
               reason: "P09R.2 unit B complete; next unit C"
             )

    assert {:error, :agent_control_request_already_exists} =
             AgentControl.request("continue", env: env)

    assert {:ok, progress} = AgentControl.read_progress(invocation)
    assert progress["unit"] == "C"
  end

  test "progress validates fields, invocation authentication, and scope", %{
    env: env,
    invocation: invocation
  } do
    assert {:error, {:agent_control_progress_required, :cursor}} =
             AgentControl.progress(" ", "summary", env: env)

    assert {:error, {:agent_control_progress_required, :summary}} =
             AgentControl.progress("P09R.2", " ", env: env)

    assert {:error, {:agent_control_environment_missing, ["PROMPT_RUNNER_AGENT_PROGRESS_FILE"]}} =
             AgentControl.progress("P09R.2", "summary",
               env: Map.delete(env, "PROMPT_RUNNER_AGENT_PROGRESS_FILE")
             )

    assert {:ok, _receipt} = AgentControl.progress("P09R.2", "summary", env: env)

    assert {:error, :agent_control_progress_mismatch} =
             AgentControl.read_progress(%{invocation | token: "wrong-token"})

    assert {:error, :agent_control_progress_mismatch} =
             AgentControl.read_progress(%{invocation | run_id: "wrong-run"})

    assert {:error, :agent_control_progress_mismatch} =
             AgentControl.read_progress(%{invocation | prompt_id: "08"})

    assert {:error, :agent_control_progress_mismatch} =
             AgentControl.read_progress(%{invocation | iteration: 4})
  end

  test "latest progress rejects another run and keeps the newest iteration", %{
    env: env,
    invocation: invocation
  } do
    assert {:ok, _receipt} = AgentControl.progress("P09R.2", "iteration three", env: env)

    assert %{"summary" => "iteration three"} =
             AgentControl.latest_progress(
               Path.dirname(Path.dirname(invocation.progress_file)),
               "run-123",
               "07"
             )

    assert AgentControl.latest_progress(
             Path.dirname(Path.dirname(invocation.progress_file)),
             "another-run",
             "07"
           ) == nil
  end

  test "finish and blocked require an audit reason", %{env: env} do
    assert {:error, :agent_control_reason_required} = AgentControl.request("finish", env: env)
    assert {:error, :agent_control_reason_required} = AgentControl.request("blocked", env: env)
  end

  test "a request cannot be written outside a live invocation" do
    assert {:error, {:agent_control_environment_missing, missing}} =
             AgentControl.request("repeat", env: %{})

    assert "PROMPT_RUNNER_AGENT_CONTROL_FILE" in missing
    assert "PROMPT_RUNNER_AGENT_CONTROL_TOKEN" in missing
  end

  test "consume rejects a request copied from another invocation", %{
    env: env,
    invocation: invocation
  } do
    assert {:ok, _receipt} = AgentControl.request("repeat", env: env)

    assert {:error, :agent_control_request_mismatch} =
             AgentControl.consume(%{invocation | token: "different-token"})
  end

  test "configuration requires a real completion contract" do
    assert {:error, :agent_control_completion_verify_required} =
             AgentControl.config(%{"enabled" => true, "max_iterations" => 20})

    assert {:ok, config} =
             AgentControl.config(%{
               "enabled" => true,
               "default_action" => "repeat",
               "max_iterations" => 20,
               "completion_verify" => %{"files_exist" => ["DONE"]}
             })

    assert config.enabled?
    assert config.default_action == :repeat
    assert config.max_iterations == 20
  end
end
