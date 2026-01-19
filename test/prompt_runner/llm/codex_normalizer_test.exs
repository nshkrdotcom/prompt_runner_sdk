defmodule PromptRunner.LLM.CodexNormalizerTest do
  use ExUnit.Case, async: true

  alias PromptRunner.LLM.CodexNormalizer
  alias Codex.Events
  alias Codex.Items

  test "normalizes message deltas and turn boundaries" do
    events = [
      struct(Events.TurnStarted, %{thread_id: "t1"}),
      struct(Events.ItemAgentMessageDelta, %{item: %{"text" => "hello"}}),
      struct(Events.TurnCompleted, %{thread_id: "t1"})
    ]

    normalized = CodexNormalizer.normalize(events, "model-x") |> Enum.to_list()

    assert [%{type: :message_start}, %{type: :text_delta, text: "hello"}, %{type: :message_stop}] =
             normalized
  end

  test "normalizes tool lifecycle from command execution items" do
    command =
      struct(Items.CommandExecution, %{
        id: "cmd-1",
        command: "ls",
        status: "completed",
        exit_code: 0,
        aggregated_output: "ok"
      })

    events = [
      struct(Events.TurnStarted, %{}),
      struct(Events.ItemStarted, %{item: command}),
      struct(Events.ItemCompleted, %{item: command}),
      struct(Events.TurnCompleted, %{})
    ]

    normalized = CodexNormalizer.normalize(events, "model-x") |> Enum.to_list()

    assert Enum.any?(normalized, &match?(%{type: :tool_use_start, name: "shell"}, &1))
    assert Enum.any?(normalized, &match?(%{type: :tool_complete, tool_name: "shell"}, &1))
    assert Enum.any?(normalized, &match?(%{type: :message_stop}, &1))
  end
end
