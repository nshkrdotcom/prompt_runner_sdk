defmodule PromptRunner.Rendering.JSONLSinkTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Rendering.Sinks.JSONLSink
  alias PromptRunner.Test.FSHelpers

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_jsonl_sink")
    path = Path.join(root, "events.jsonl")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, path: path}
  end

  test "reopening a sink appends resumed events instead of truncating the first stream", %{
    path: path
  } do
    write_event(path, :run_started, %{model: "first"})
    write_event(path, :run_completed, %{stop_reason: "resumed"})

    assert [first, second] =
             path
             |> File.stream!()
             |> Enum.map(&Jason.decode!/1)

    assert first["type"] == "run_started"
    assert second["type"] == "run_completed"
  end

  defp write_event(path, type, data) do
    {:ok, state} = JSONLSink.init(path: path)
    {:ok, state} = JSONLSink.write_event(%{type: type, data: data}, [], state)
    {:ok, state} = JSONLSink.flush(state)
    :ok = JSONLSink.close(state)
  end
end
