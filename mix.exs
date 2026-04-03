defmodule PromptRunner.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/nshkrdotcom/prompt_runner_sdk"

  def project do
    [
      app: :prompt_runner_sdk,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]],
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
      extra_applications: [:logger, :inets],
      mod: {PromptRunner.Application, []}
    ]
  end

  defp deps do
    [
      local_or_hex_dep(:agent_session_manager, "~> 0.10.1", "../agent_session_manager"),
      {:jason, "~> 1.4"},

      # Agent SDKs (optional — consumers add the ones they need)
      local_or_hex_dep(:codex_sdk, "~> 0.15.0", "../codex_sdk", optional: true),
      local_or_hex_dep(:claude_agent_sdk, "~> 0.16.0", "../claude_agent_sdk", optional: true),
      local_or_hex_dep(:amp_sdk, "~> 0.4.0", "../amp_sdk", optional: true),
      local_or_hex_dep(:gemini_cli_sdk, "~> 0.1.0", "../gemini_cli_sdk", optional: true),
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.40.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp local_or_hex_dep(app, version, relative_path, opts \\ []) do
    path = Path.expand(relative_path, __DIR__)

    if File.dir?(path) do
      {app, version, Keyword.put(opts, :path, relative_path)}
    else
      {app, version, opts}
    end
  end

  defp description do
    """
    Prompt Runner SDK - Convention-driven and legacy-config prompt orchestration
    for Elixir, Mix, and production applications with streaming output,
    provider abstractions, runtime stores, and git integration.
    """
  end

  defp escript do
    [
      main_module: PromptRunner.CLI,
      name: "prompt_runner"
    ]
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
        {"guides/getting-started.md", filename: "getting-started", title: "Getting Started"},
        {"guides/convention-mode.md", filename: "convention-mode", title: "Convention Mode"},
        {"guides/cli.md", filename: "cli", title: "CLI Guide"},
        {"guides/api.md", filename: "api", title: "API Guide"},
        {"guides/configuration.md", filename: "configuration", title: "Configuration Reference"},
        {"guides/legacy-config.md", filename: "legacy-config", title: "Legacy Config Mode"},
        {"guides/providers.md", filename: "providers", title: "Provider Guide"},
        {"guides/rendering.md", filename: "rendering", title: "Rendering Modes"},
        {"guides/multi-repo.md", filename: "multi-repo", title: "Multi-Repository Workflows"},
        {"guides/architecture.md", filename: "architecture", title: "Architecture"},
        {"guides/migration.md", filename: "migration", title: "Migration Notes"},
        {"examples/README.md", filename: "examples", title: "Examples Overview"},
        {"examples/simple/README.md", filename: "example-simple", title: "Simple Example"},
        {"examples/multi_repo_dummy/README.md",
         filename: "example-multi-repo", title: "Multi-Repo Example"}
      ],
      groups_for_extras: [
        Overview: ["readme", "getting-started"],
        Workflows: [
          "convention-mode",
          "cli",
          "api",
          "legacy-config",
          "multi-repo"
        ],
        Configuration: [
          "configuration",
          "providers",
          "rendering"
        ],
        Architecture: [
          "architecture",
          "migration"
        ],
        Examples: [
          "examples",
          "example-simple",
          "example-multi-repo"
        ],
        Reference: [
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          PromptRunner,
          PromptRunner.Run,
          PromptRunner.RunSpec,
          PromptRunner.Plan,
          PromptRunner.Application,
          PromptRunner.CLI,
          Mix.Tasks.PromptRunner
        ],
        Sources: [
          PromptRunner.Source,
          PromptRunner.Source.Result,
          PromptRunner.Source.DirectorySource,
          PromptRunner.Source.LegacyConfigSource,
          PromptRunner.Source.ListSource,
          PromptRunner.Source.SinglePromptSource
        ],
        Runtime: [
          PromptRunner.Runner,
          PromptRunner.RuntimeStore,
          PromptRunner.RuntimeStore.FileStore,
          PromptRunner.RuntimeStore.MemoryStore,
          PromptRunner.RuntimeStore.NoopStore,
          PromptRunner.Committer,
          PromptRunner.Committer.GitCommitter,
          PromptRunner.Committer.NoopCommitter,
          PromptRunner.Committer.CallbackCommitter
        ],
        Configuration: [
          PromptRunner.Config,
          PromptRunner.Prompts,
          PromptRunner.Prompt,
          PromptRunner.CommitMessages,
          PromptRunner.Progress,
          PromptRunner.Scaffold
        ],
        "LLM Integration": [
          PromptRunner.LLM,
          PromptRunner.LLMFacade,
          PromptRunner.Session
        ],
        Observability: [
          PromptRunner.Observer.PubSub,
          PromptRunner.UI
        ],
        Utilities: [
          PromptRunner.Validator,
          PromptRunner.RepoTargets,
          PromptRunner.Git
        ]
      ]
    ]
  end

  defp package do
    [
      name: "prompt_runner_sdk",
      description: description(),
      files:
        ~w(lib guides examples assets mix.exs README.md CHANGELOG.md LICENSE run_prompts.exs),
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
