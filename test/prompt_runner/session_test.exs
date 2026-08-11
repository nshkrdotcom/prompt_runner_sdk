defmodule PromptRunner.SessionTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Session

  @emergency_timeout_ms 604_800_000

  test "effective_timeout_ms_for_config uses explicit positive timeout" do
    assert Session.effective_timeout_ms_for_config(%{timeout: 42_000}) == 42_000
  end

  test "effective_timeout_ms_for_config supports unbounded sentinel values" do
    assert Session.effective_timeout_ms_for_config(%{timeout: :unbounded}) ==
             @emergency_timeout_ms

    assert Session.effective_timeout_ms_for_config(%{timeout: :infinity}) == @emergency_timeout_ms

    assert Session.effective_timeout_ms_for_config(%{timeout: "infinity"}) ==
             @emergency_timeout_ms
  end

  test "effective_timeout_ms_for_config falls back to emergency timeout when missing" do
    assert Session.effective_timeout_ms_for_config(%{}) == @emergency_timeout_ms
  end

  test "effective_timeout_ms_for_config can derive timeout from adapter_opts" do
    assert Session.effective_timeout_ms_for_config(%{adapter_opts: %{timeout: "123000"}}) ==
             123_000
  end

  test "effective_timeout_ms_for_config clamps configured timeout to emergency cap" do
    assert Session.effective_timeout_ms_for_config(%{timeout: @emergency_timeout_ms + 1}) ==
             @emergency_timeout_ms
  end

  test "build_run_opts_for_config always sets adapter timeout and preserves run context options" do
    opts =
      Session.build_run_opts_for_config(%{
        timeout: :unbounded,
        context: %{trace_id: "abc"},
        continuation: :auto,
        continuation_opts: [max_messages: 50]
      })

    assert opts[:context] == %{trace_id: "abc"}
    assert opts[:continuation] == :auto
    assert opts[:continuation_opts] == [max_messages: 50]
    assert opts[:adapter_opts][:timeout] == @emergency_timeout_ms
  end

  test "resolve_stream_idle_timeout_for_config derives from effective timeout when not explicitly set" do
    assert Session.resolve_stream_idle_timeout_for_config(%{timeout: :unbounded}) ==
             @emergency_timeout_ms + 30_000
  end

  test "resolve_stream_idle_timeout_for_config respects explicit idle timeout settings" do
    assert Session.resolve_stream_idle_timeout_for_config(%{stream_idle_timeout: 777_000}) ==
             777_000

    assert Session.resolve_stream_idle_timeout_for_config(%{idle_timeout: 888_000}) == 888_000
  end

  test "codex hidden confirmation run_started captures provider session id and raw metadata" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_session_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    script_path = Path.join(tmp_dir, "codex_fixture.sh")

    File.write!(
      script_path,
      """
      #!/usr/bin/env bash
      printf '%s\\n' '{"type":"thread.started","thread_id":"thr_probe","metadata":{"labels":{"topic":"demo"}}}'
      printf '%s\\n' '{"type":"turn.completed","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
      """
    )

    File.chmod!(script_path, 0o755)

    llm = %{
      provider: "codex",
      model: "gpt-5.4",
      cwd: tmp_dir,
      permission_mode: :bypass,
      codex_thread_opts: %{reasoning_effort: :xhigh},
      sdk_opts: %{cli_path: script_path}
    }

    {:ok, stream, close_fun, meta} = Session.start_stream(llm, "say ok")
    events = Enum.take(stream, 10)
    close_fun.()

    hidden_run_started =
      Enum.find(events, fn
        %{type: :run_started, hidden?: true} -> true
        _ -> false
      end)

    assert hidden_run_started.data.provider_session_id == "thr_probe"
    assert hidden_run_started.data.metadata["labels"] == %{"topic" => "demo"}
    assert meta.session_opts[:lane] == :core
    assert meta.session_opts[:owner] == self()
  end

  # These drive the whole chain the way a real run does: a fixture CLI writes
  # the JSONL `codex exec --json` actually writes, cli_subprocess_core decodes
  # it, and the bridge turns it into the events a renderer consumes.
  defp codex_stream(lines, extra_llm \\ %{}) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_session_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    script_path = Path.join(tmp_dir, "codex_fixture.sh")
    body = Enum.map_join(lines, "\n", &"printf '%s\\n' '#{&1}'")
    File.write!(script_path, "#!/usr/bin/env bash\n" <> body <> "\n")
    File.chmod!(script_path, 0o755)

    llm =
      Map.merge(
        %{
          provider: "codex",
          model: "gpt-5.6-sol",
          cwd: tmp_dir,
          permission_mode: :bypass,
          codex_thread_opts: %{reasoning_effort: :xhigh},
          sdk_opts: %{cli_path: script_path}
        },
        extra_llm
      )

    {:ok, stream, close_fun, _meta} = Session.start_stream(llm, "say ok")
    events = Enum.take(stream, 30)
    close_fun.()
    events
  end

  defp visible(events, type) do
    Enum.filter(events, &(&1.type == type and not Map.get(&1, :hidden?, false)))
  end

  test "a codex run reports the model it launched with, not 'unknown'" do
    events = codex_stream([~s({"type":"turn.completed","stop_reason":"end_turn"})])

    assert [run_started] = visible(events, :run_started)
    assert run_started.data.model == "gpt-5.6-sol"
    assert run_started.data.reasoning_effort == "xhigh"

    # The requested model is for display only. Confirmation still depends on
    # the provider echoing it back, which this fixture never does.
    refute Map.has_key?(run_started.data, :confirmed_model)
  end

  test "a codex shell command surfaces as a tool call and a tool result" do
    events =
      codex_stream([
        ~s({"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"mix test"}}),
        ~s({"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"mix test","aggregated_output":"16 tests, 0 failures","exit_code":0,"status":"completed"}}),
        ~s({"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"the suite is green"}}),
        ~s({"type":"turn.completed","stop_reason":"end_turn"})
      ])

    assert [started] = visible(events, :tool_call_started)
    assert started.data.tool_name == "Bash"
    assert started.data.tool_input["command"] == "mix test"

    assert [completed] = visible(events, :tool_call_completed)
    assert completed.data.tool_call_id == started.data.tool_call_id
    assert completed.data.tool_output == "16 tests, 0 failures"

    assert [message] = visible(events, :message_received)
    assert message.data.content == "the suite is green"
  end

  # The Codex lane reports a tool as an item that has already completed, so
  # blocking it prevents nothing and only kills a run that was working. This
  # killed a live packet's prompt 02 on `TodoWrite` the moment Codex tool
  # decoding started working.
  test "a tool outside allowed_tools is recorded on the event, not fatal, on the codex lane" do
    events =
      codex_stream(
        [
          ~s({"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"mix test"}}),
          ~s({"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"mix test","aggregated_output":"ok","exit_code":0,"status":"completed"}}),
          ~s({"type":"turn.completed","stop_reason":"end_turn"})
        ],
        %{allowed_tools: ["Read"]}
      )

    assert [started] = visible(events, :tool_call_started)
    assert started.data.tool_name == "Bash"

    assert started.data.guardrail.action == :recorded
    assert started.data.guardrail.rule == :allowed_tools
    assert started.data.guardrail.tool_name == "Bash"
    assert started.data.guardrail.allowed_tools == ["Read"]

    assert visible(events, :error_occurred) == []
    assert visible(events, :run_failed) == []
    assert [_completed] = visible(events, :run_completed)
  end

  test "a tool inside allowed_tools carries no guardrail record" do
    events =
      codex_stream(
        [
          ~s({"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"mix test"}}),
          ~s({"type":"turn.completed","stop_reason":"end_turn"})
        ],
        %{allowed_tools: ["Bash"]}
      )

    assert [started] = visible(events, :tool_call_started)
    refute Map.has_key?(started.data, :guardrail)
  end

  test "a failing codex command renders as a failed tool call" do
    events =
      codex_stream([
        ~s({"type":"item.completed","item":{"id":"i","type":"command_execution","aggregated_output":"boom","exit_code":1,"status":"failed"}}),
        ~s({"type":"turn.completed","stop_reason":"end_turn"})
      ])

    assert [failed] = visible(events, :tool_call_failed)
    assert failed.data.tool_output == "boom"
  end

  # Without this the run has no terminal event at all: the provider stops
  # talking and the consumer waits for a result that never comes.
  test "a failed codex turn terminates the run instead of going silent" do
    events =
      codex_stream([
        ~s({"type":"turn.failed","error":{"message":"You have hit your usage limit."}})
      ])

    assert [error] = visible(events, :error_occurred)
    assert error.data.error_message =~ "usage limit"

    assert [failed] = visible(events, :run_failed)
    assert failed.data.error_message =~ "usage limit"
  end
end
