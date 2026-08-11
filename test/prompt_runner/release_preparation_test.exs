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

    assert project[:elixir] == "~> 1.19"

    # The dependency tuple's shape varies by resolved source (path/github/hex),
    # so the committed constraint is asserted at its source of truth instead.
    # The assertion is on the *line*, not the patch: a patch bump in a sibling
    # is an ordinary event, and pinning the digit here turned every one of them
    # into a failing suite in this repository.
    config = DependencySources.config!(Path.expand("../..", __DIR__))

    assert config[:deps][:agent_session_manager][:hex] =~ ~r/^~> 0\.12\./
    assert config[:deps][:cli_subprocess_core][:hex] =~ ~r/^~> 0\.5\./

    assert List.keymember?(project[:deps], :agent_session_manager, 0)
    assert List.keymember?(project[:deps], :cli_subprocess_core, 0)
  end

  test "mix.exs version matches the newest CHANGELOG entry" do
    # The release checklist requires both a bump and a CHANGELOG entry. Asserting
    # a version literal in this file only proves someone edited this file;
    # asserting the two agree proves the entry was actually written.
    changelog = File.read!(Path.expand("../../CHANGELOG.md", __DIR__))

    assert [_, newest] = Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, changelog)
    assert Mix.Project.config()[:version] == newest
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

  test "every documentation extra exists and is grouped" do
    docs = Mix.Project.config()[:docs]
    root = Path.expand("../..", __DIR__)

    extras =
      Enum.map(docs[:extras], fn
        {path, opts} -> {to_string(path), opts[:filename] || Path.basename(path)}
        path -> {to_string(path), to_string(path)}
      end)

    missing = Enum.reject(extras, fn {path, _name} -> File.regular?(Path.join(root, path)) end)

    assert missing == [], "documentation extras missing from disk: #{inspect(missing)}"

    grouped = docs[:groups_for_extras] |> Keyword.values() |> List.flatten()
    ungrouped = extras |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 in grouped))

    assert ungrouped == [], "documentation extras with no group: #{inspect(ungrouped)}"
  end

  test "every guide on disk is published" do
    root = Path.expand("../..", __DIR__)

    published =
      Mix.Project.config()[:docs][:extras]
      |> Enum.map(fn
        {path, _opts} -> to_string(path)
        path -> to_string(path)
      end)

    unpublished =
      root
      |> Path.join("guides/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in published))

    assert unpublished == [],
           "guides not registered in mix.exs docs.extras: #{inspect(unpublished)}"
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
