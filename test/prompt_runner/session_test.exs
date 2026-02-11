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
end
