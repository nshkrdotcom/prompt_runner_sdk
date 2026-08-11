defmodule PromptRunner.Rendering.StudioRendererTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Rendering.Renderers.StudioRenderer

  defp new_state do
    {:ok, state} = StudioRenderer.init(color: false, tty: false, show_spinner: false)
    state
  end

  defp render(events) do
    {output, _state} =
      Enum.reduce(events, {[], new_state()}, fn event, {acc, state} ->
        {:ok, iodata, state} = StudioRenderer.render_event(event, state)
        {[acc, iodata], state}
      end)

    IO.iodata_to_binary(output)
  end

  defp event(type, data), do: %{type: type, data: data}

  describe "the session header" do
    test "names the model the run actually launched with" do
      assert render([event(:run_started, %{model: "gpt-5.6-sol"})]) =~
               "gpt-5.6-sol session started"
    end

    test "includes reasoning effort when the run asked for one" do
      output = render([event(:run_started, %{model: "gpt-5.6-sol", reasoning_effort: "xhigh"})])
      assert output =~ "gpt-5.6-sol (xhigh) session started"
    end

    test "says nothing rather than 'unknown' when no model is named" do
      output = render([event(:run_started, %{})])
      assert output =~ "session started"
      refute output =~ "unknown"
    end
  end

  describe "assistant text" do
    # Codex delivers a message whole; Claude streams it in deltas. Both must
    # end up on screen exactly once.
    test "a provider that does not stream still shows its message" do
      output = render([event(:message_received, %{content: "the inventory is now closed"})])
      assert output =~ "the inventory is now closed"
    end

    test "a provider that streams does not have its message printed twice" do
      output =
        render([
          event(:message_streamed, %{delta: "hello "}),
          event(:message_streamed, %{delta: "world"}),
          event(:message_received, %{content: "hello world"})
        ])

      assert output =~ "hello world"
      assert count(output, "hello world") == 1
    end

    test "reasoning does not stand in for the message it precedes" do
      output =
        render([
          event(:message_streamed, %{delta: "weighing the options", kind: :thinking}),
          event(:message_received, %{content: "here is the answer"})
        ])

      assert output =~ "weighing the options"
      assert output =~ "here is the answer"
    end

    test "each message in a run is shown, not just the first" do
      output =
        render([
          event(:message_received, %{content: "first"}),
          event(:message_received, %{content: "second"})
        ])

      assert output =~ "first"
      assert output =~ "second"
    end

    test "a streamed message does not suppress the next unstreamed one" do
      output =
        render([
          event(:message_streamed, %{delta: "streamed"}),
          event(:message_received, %{content: "streamed"}),
          event(:message_received, %{content: "delivered whole"})
        ])

      assert count(output, "streamed") == 1
      assert output =~ "delivered whole"
    end
  end

  describe "tool calls" do
    test "a tool call and its result are both rendered" do
      output =
        render([
          event(:tool_call_started, %{
            tool_name: "bash",
            tool_call_id: "item_3",
            tool_input: %{"command" => "mix test"}
          }),
          event(:tool_call_completed, %{
            tool_call_id: "item_3",
            tool_output: "16 tests, 0 failures"
          })
        ])

      assert output =~ "mix test"
    end
  end

  defp count(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
