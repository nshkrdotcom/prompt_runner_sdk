defmodule PromptRunner.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/prompt_runner_sdk"

  def project do
    [
      app: :prompt_runner_sdk,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "PromptRunnerSDK",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:claude_agent_sdk, "~> 0.9.0"},
      {:codex_sdk, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Prompt Runner SDK - An Elixir toolkit for orchestrating multi-step prompt
    executions with Claude Agent SDK and Codex SDK. Features streaming output,
    progress tracking, multi-repository support, and automatic git integration.
    """
  end

  defp docs do
    [
      main: "readme",
      name: "PromptRunnerSDK",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/prompt_runner_sdk.svg",
      extras: [
        {"README.md", filename: "readme", title: "Prompt Runner SDK"},
        "CHANGELOG.md",
        "LICENSE",
        # Examples
        {"examples/README.md", filename: "examples", title: "Examples Overview"},
        {"examples/simple/README.md", filename: "example-simple", title: "Simple Example"},
        {"examples/multi_repo_dummy/README.md",
         filename: "example-multi-repo", title: "Multi-Repo Example"}
      ],
      groups_for_extras: [
        Introduction: ["readme"],
        Guides: ["CHANGELOG.md", "LICENSE"],
        Examples: [
          "examples",
          "example-simple",
          "example-multi-repo"
        ]
      ],
      groups_for_modules: [
        "Core API": [PromptRunner, PromptRunner.Runner, PromptRunner.CLI],
        Configuration: [PromptRunner.Config, PromptRunner.Prompts, PromptRunner.Prompt],
        "LLM Integration": [PromptRunner.LLM, PromptRunner.LLMFacade],
        "Progress & Git": [PromptRunner.Progress, PromptRunner.Git, PromptRunner.CommitMessages],
        Rendering: [PromptRunner.StreamRenderer, PromptRunner.UI],
        Utilities: [PromptRunner.Validator]
      ]
    ]
  end

  defp package do
    [
      name: "prompt_runner_sdk",
      description: description(),
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["nshkrdotcom"],
      exclude_patterns: [
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end
end
