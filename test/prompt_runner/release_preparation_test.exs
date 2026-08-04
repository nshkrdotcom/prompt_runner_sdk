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

  test "release metadata follows the ASM 0.12 and Elixir 1.19 boundary" do
    project = Mix.Project.config()

    assert project[:version] == "0.8.1"
    assert project[:elixir] == "~> 1.19"

    # The dependency tuple's shape varies by resolved source (path/github/hex),
    # so the committed constraint is asserted at its source of truth instead.
    config = DependencySources.config!(Path.expand("../..", __DIR__))

    assert config[:deps][:agent_session_manager][:hex] == "~> 0.12.1"
    assert config[:deps][:cli_subprocess_core][:hex] == "~> 0.4.1"

    assert List.keymember?(project[:deps], :agent_session_manager, 0)
    assert List.keymember?(project[:deps], :cli_subprocess_core, 0)
  end

  test "publish preflight accepts the committed hex constraints" do
    assert {:ok, _entries} = DependencySources.publish_preflight(Path.expand("../..", __DIR__))
  end

  test "the emitted version is derived from mix.exs" do
    assert PromptRunner.version() == Mix.Project.config()[:version]
  end

  test "no source file hardcodes a release version" do
    # Generated packets, scaffolds, and CLI output must interpolate
    # PromptRunner.version/0. A literal here silently ships a stale version.
    literals =
      ~r/prompt_runner_sdk[^\n]{0,12}~>\s*\d+\.\d+\.\d+|Prompt Runner\s+\d+\.\d+\.\d+/

    offenders =
      Path.expand("../../lib", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _no} -> Regex.match?(literals, line) end)
        |> Enum.map(fn {line, no} ->
          "#{Path.relative_to_cwd(path)}:#{no}: #{String.trim(line)}"
        end)
      end)

    assert offenders == [],
           "hardcoded version literals found:\n  " <> Enum.join(offenders, "\n  ")
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
