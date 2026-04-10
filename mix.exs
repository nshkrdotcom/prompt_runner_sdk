defmodule PromptRunner.MixProject do
  use Mix.Project

  @version "0.7.0"
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
      local_dev_or_hex_dep(:agent_session_manager, "~> 0.9.2", "../agent_session_manager"),
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:mox, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.40.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp local_dev_or_hex_dep(app, version, relative_path, opts \\ []) do
    path = Path.expand(relative_path, __DIR__)

    if use_local_dev_deps?() and File.dir?(path) do
      {app, version, Keyword.put(opts, :path, relative_path)}
    else
      {app, version, opts}
    end
  end

  defp use_local_dev_deps? do
    truthy_env?("PROMPT_RUNNER_USE_LOCAL_DEPS") and not hex_packaging_task?()
  end

  defp truthy_env?(name) do
    System.get_env(name) in ~w(1 true TRUE yes YES on ON)
  end

  defp hex_packaging_task? do
    Enum.any?(System.argv(), &(&1 in ["hex.build", "hex.publish", "hex.package"]))
  end

  defp description do
    """
    Prompt Runner SDK - packet-first prompt execution for Elixir and CLI
    workflows with verifier-owned completion, retry, repair, and git-aware
    repository orchestration.
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
        {"guides/cli.md", filename: "cli", title: "CLI Guide"},
        {"guides/api.md", filename: "api", title: "API Guide"},
        {"guides/configuration.md",
         filename: "configuration", title: "Packet Manifest Reference"},
        {"guides/profiles.md", filename: "profiles", title: "Profiles"},
        {"guides/providers.md", filename: "providers", title: "Provider Guide"},
        {"guides/verification-and-repair.md",
         filename: "verification-and-repair", title: "Verification And Repair"},
        {"guides/rendering.md", filename: "rendering", title: "Rendering Modes"},
        {"guides/multi-repo.md", filename: "multi-repo", title: "Multi-Repository Packets"},
        {"guides/architecture.md", filename: "architecture", title: "Architecture"},
        {"examples/README.md", filename: "examples", title: "Examples Overview"},
        {"examples/single_repo_packet/README.md",
         filename: "example-single-repo", title: "Single Repo Packet Example"},
        {"examples/multi_repo_packet/README.md",
         filename: "example-multi-repo", title: "Multi-Repo Packet Example"}
      ],
      groups_for_extras: [
        Overview: ["readme", "getting-started"],
        Authoring: ["cli", "configuration", "profiles", "multi-repo"],
        Configuration: [
          "configuration",
          "providers",
          "verification-and-repair",
          "rendering"
        ],
        Embedding: ["api"],
        Architecture: ["architecture"],
        Examples: [
          "examples",
          "example-single-repo",
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
          PromptRunner.Packet,
          PromptRunner.Packets,
          PromptRunner.Profile,
          PromptRunner.Verifier,
          PromptRunner.Runtime,
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
          PromptRunner.Source.PacketSource,
          PromptRunner.Source.DirectorySource,
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
          PromptRunner.Prompt,
          PromptRunner.FrontMatter,
          PromptRunner.Paths,
          PromptRunner.PermissionMode,
          PromptRunner.ProviderOptions
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
        Compatibility: [
          PromptRunner.Source.LegacyConfigSource,
          PromptRunner.Prompts,
          PromptRunner.CommitMessages,
          PromptRunner.Progress,
          PromptRunner.Scaffold,
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
        "examples/**/.prompt_runner",
        "examples/**/.prompt_runner/**",
        "examples/**/workspace",
        "examples/**/workspace/**",
        "examples/**/repos",
        "examples/**/repos/**",
        "examples/**/logs",
        "examples/**/logs/**",
        "examples/**/.progress",
        "examples/**/.git",
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end
end
