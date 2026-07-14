defmodule PromptRunner.ReleasePreparationTest do
  use ExUnit.Case, async: true

  test "package uses an explicit example-source allowlist" do
    package = Mix.Project.config()[:package]
    files = package[:files]

    refute "examples" in files
    assert "examples/README.md" in files
    assert "examples/*_packet/prompts/*.prompt.md" in files
    assert "examples/authoring_packet/docs/*.md" in files
    assert "examples/authoring_packet/templates/*.md" in files
  end

  test "release metadata follows the ASM 0.10 and Elixir 1.19 boundary" do
    project = Mix.Project.config()

    assert project[:version] == "0.7.0"
    assert project[:elixir] == "~> 1.19"

    assert {:agent_session_manager, "~> 0.10.0", _opts} =
             List.keyfind(project[:deps], :agent_session_manager, 0)
  end
end
