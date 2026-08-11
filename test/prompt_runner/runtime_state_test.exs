defmodule PromptRunner.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Runtime
  alias PromptRunner.Test.FSHelpers

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_runtime_state")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "an invocation result updates only its newest running attempt", %{root: root} do
    prompt = %{num: "01", name: "Step"}

    :ok = Runtime.record_attempt_started(root, prompt, 1, "run")
    :ok = Runtime.record_attempt_result(root, "01", 1, %{status: "failed", reason: "first"})

    # Attempt numbers intentionally restart when the CLI is invoked again.
    :ok = Runtime.record_attempt_started(root, prompt, 1, "run")
    :ok = Runtime.record_attempt_result(root, "01", 1, %{status: "completed", reason: "second"})

    assert {:ok, [first, second]} = Runtime.get_attempts(root, "01")
    assert first["status"] == "failed"
    assert first["reason"] == "first"
    assert second["status"] == "completed"
    assert second["reason"] == "second"
  end

  test "state replacement leaves a complete JSON document and no temporary files", %{root: root} do
    prompt = %{num: "01", name: "Step"}

    Enum.each(1..20, fn attempt ->
      :ok = Runtime.record_attempt_started(root, prompt, attempt, "run")
      :ok = Runtime.record_attempt_result(root, "01", attempt, %{status: "completed"})
      assert {:ok, _state} = Runtime.get_status(root)
    end)

    state_path = Runtime.state_path(root)
    assert {:ok, _decoded} = state_path |> File.read!() |> Jason.decode()
    assert Path.wildcard(state_path <> ".tmp.*") == []
  end
end
