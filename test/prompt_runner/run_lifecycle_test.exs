defmodule PromptRunner.RunLifecycleTest do
  use ExUnit.Case, async: true

  alias PromptRunner.{Plan, Prompt, RunLifecycle}
  alias PromptRunner.Test.FSHelpers

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_lifecycle")
    state_dir = Path.join(root, "state")

    plan = %Plan{
      source_root: Path.join(root, "packet"),
      state_dir: state_dir,
      prompts: [
        %Prompt{num: "01", name: "One", file: "01.prompt.md"},
        %Prompt{num: "02", name: "Two", file: "02.prompt.md"},
        %Prompt{num: "17", name: "Seventeen", file: "17.prompt.md"}
      ]
    }

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, plan: plan, state_dir: state_dir}
  end

  test "a failed run resumes only inside its persisted exact fence", %{plan: plan} do
    assert {:ok, first} =
             RunLifecycle.open(plan, ["01", "02"], %{remaining: true, through: "02"})

    assert first.upper_fence == "02"
    assert :ok = RunLifecycle.transition(first, "failed")

    assert {:ok, resumed} = RunLifecycle.open(plan, ["02"], %{remaining: true})
    assert resumed.run_id == first.run_id
    assert resumed.targets == ["02"]
    assert resumed.upper_fence == "02"

    assert {:error, {:selection_fence_widening, ["17"]}} =
             RunLifecycle.open(plan, ["02", "17"], %{remaining: true})
  end

  test "a completed run permits a fresh identity and selection", %{plan: plan} do
    assert {:ok, first} = RunLifecycle.open(plan, ["01"], %{all: false})
    assert :ok = RunLifecycle.transition(first, "completed")
    assert {:ok, second} = RunLifecycle.open(plan, ["17"], %{all: false})
    refute second.run_id == first.run_id
  end

  test "a changed packet cannot resume the previous run", %{plan: plan} do
    assert {:ok, first} = RunLifecycle.open(plan, ["01"], %{})
    assert :ok = RunLifecycle.transition(first, "failed")

    changed = %{plan | prompts: [%Prompt{num: "01", name: "Changed", file: "01.prompt.md"}]}
    assert {:error, :run_packet_fingerprint_changed} = RunLifecycle.open(changed, ["01"], %{})
  end
end
