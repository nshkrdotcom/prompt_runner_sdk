defmodule PromptRunner.MixTaskTest do
  use ExUnit.Case, async: false

  test "mix task delegates to the CLI entrypoint" do
    assert Code.ensure_loaded?(Mix.Tasks.PromptRunner)
    assert function_exported?(Mix.Tasks.PromptRunner, :run, 1)
  end
end
