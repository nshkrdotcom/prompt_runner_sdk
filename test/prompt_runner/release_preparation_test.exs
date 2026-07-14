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

  test "Hex metadata and documentation use the release presentation assets" do
    project = Mix.Project.config()
    package = project[:package]
    docs = project[:docs]

    assert project[:homepage_url] == "https://hex.pm/packages/prompt_runner_sdk"
    assert docs[:homepage_url] == "https://hexdocs.pm/prompt_runner_sdk"
    assert docs[:logo] == "assets/prompt_runner_sdk.svg"
    assert docs[:assets] == %{"assets" => "assets"}

    assert package[:links] == %{
             "Changelog" =>
               "https://github.com/nshkrdotcom/prompt_runner_sdk/blob/main/CHANGELOG.md",
             "GitHub" => "https://github.com/nshkrdotcom/prompt_runner_sdk",
             "Hex" => "https://hex.pm/packages/prompt_runner_sdk",
             "HexDocs" => "https://hexdocs.pm/prompt_runner_sdk",
             "License" => "https://github.com/nshkrdotcom/prompt_runner_sdk/blob/main/LICENSE"
           }
  end

  test "README has the centered 200px logo and exactly the GitHub and MIT badges" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert readme =~
             ~s(<img src="assets/prompt_runner_sdk.svg" alt="Prompt Runner SDK" width="200" height="200">)

    assert readme =~ ~s(href="https://github.com/nshkrdotcom/prompt_runner_sdk")
    assert readme =~ ~s(href="LICENSE")
    assert length(Regex.scan(~r/img\.shields\.io/, readme)) == 2
  end
end
