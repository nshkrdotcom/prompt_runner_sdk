defmodule PromptRunner.SchedulerTest do
  use ExUnit.Case, async: true

  alias PromptRunner.{Plan, Prompt, Scheduler}

  test "dependencies are topologically ordered while independent prompts retain selection order" do
    plan = %Plan{
      prompts: [
        %Prompt{num: "01", depends_on: []},
        %Prompt{num: "02", depends_on: ["01"]},
        %Prompt{num: "03", depends_on: []}
      ]
    }

    assert {:ok, ["03", "01", "02"]} = Scheduler.order(plan, ["03", "02", "01"])
  end

  test "unknown dependencies and cycles are hard planning errors" do
    unknown = %Plan{prompts: [%Prompt{num: "01", depends_on: ["99"]}]}

    assert {:error, {:invalid_prompt_dependencies, [%{prompt: "01", unknown_dependency: "99"}]}} =
             Scheduler.validate(unknown)

    cyclic = %Plan{
      prompts: [
        %Prompt{num: "01", depends_on: ["02"]},
        %Prompt{num: "02", depends_on: ["01"]}
      ]
    }

    assert {:error, {:prompt_dependency_cycle, ["01", "02"]}} = Scheduler.validate(cyclic)
  end
end
