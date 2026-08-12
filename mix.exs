# `build_support/` is not shipped in the published package, so its absence is
# how this file knows it is running inside a consumer's deps/ rather than in a
# source checkout.
workspace_helper = Path.expand("build_support/dependency_sources.exs", __DIR__)

if File.regular?(workspace_helper) and not Code.ensure_loaded?(DependencySources) do
  Code.require_file(workspace_helper)
end

defmodule PromptRunner.MixProject do
  use Mix.Project

  @workspace_checkout? File.regular?(Path.expand("build_support/dependency_sources.exs", __DIR__))

  @version "0.13.0"
  @source_url "https://github.com/nshkrdotcom/prompt_runner_sdk"
  @homepage_url "https://hex.pm/packages/prompt_runner_sdk"
  @docs_url "https://hexdocs.pm/prompt_runner_sdk"

  def project do
    [
      app: :prompt_runner_sdk,
      version: @version,
      elixir: "~> 1.19",
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
      homepage_url: @homepage_url
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
      workspace_dep(:agent_session_manager, "~> 0.15.0"),
      workspace_dep(:cli_subprocess_core, "~> 0.7.0"),
      workspace_dep(:execution_plane_process, "~> 0.3.0"),
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:mox, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      # 1.7.19+ tokenizes Elixir 1.20 sigils; older releases crash on them.
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  # In a source checkout the registry decides the source (path first). In a
  # published package there is no registry, and the requirement stated here is
  # the whole answer.
  defp workspace_dep(app, hex_requirement) do
    if @workspace_checkout? do
      apply(DependencySources, :dep, [app, __DIR__])
    else
      {app, hex_requirement}
    end
  end

  defp description do
    """
    Prompt Runner SDK - packet-first prompt execution for Elixir and CLI
    workflows with verifier-owned or agent-owned completion, retry, repair,
    and git-aware repository orchestration.
    """
  end

  defp escript do
    [
      main_module: PromptRunner.Escript,
      name: "prompt_runner",
      app: nil,
      include_priv_for: [:erlexec]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "PromptRunnerSDK",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/prompt_runner_sdk.svg",
      extras: [
        {"README.md", filename: "readme", title: "Prompt Runner SDK"},
        "CHANGELOG.md",
        "LICENSE",
        {"guides/getting-started.md", filename: "getting-started", title: "Getting Started"},
        {"guides/from-adrs-to-packets.md",
         filename: "from-adrs-to-packets", title: "From ADRs To Packets"},
        {"guides/cli.md", filename: "cli", title: "CLI Guide"},
        {"guides/api.md", filename: "api", title: "API Guide"},
        {"guides/configuration.md",
         filename: "configuration", title: "Packet Manifest Reference"},
        {"guides/templates.md", filename: "templates", title: "Templates"},
        {"guides/profiles.md", filename: "profiles", title: "Profiles"},
        {"guides/providers.md", filename: "providers", title: "Provider Guide"},
        {"guides/simulated-provider.md",
         filename: "simulated-provider", title: "Simulated Provider"},
        {"guides/verification-and-repair.md",
         filename: "verification-and-repair", title: "Verification And Repair"},
        {"guides/linting.md", filename: "linting", title: "Packet Linting"},
        {"guides/supervision.md", filename: "supervision", title: "Supervising A Long Run"},
        {"guides/workspaces.md", filename: "workspaces", title: "Operator Workspaces"},
        {"guides/rendering.md", filename: "rendering", title: "Rendering Modes"},
        {"guides/control.md", filename: "control", title: "Watching And Steering A Live Run"},
        {"guides/agent-control.md",
         filename: "agent-control", title: "Agent-Controlled Linear Runs"},
        {"guides/multi-repo.md", filename: "multi-repo", title: "Multi-Repository Packets"},
        {"guides/architecture.md", filename: "architecture", title: "Architecture"},
        {"examples/README.md", filename: "examples", title: "Examples Overview"},
        {"examples/authoring_packet/README.md",
         filename: "example-authoring", title: "Authoring From ADRs Packet Example"},
        {"examples/single_repo_packet/README.md",
         filename: "example-single-repo", title: "Single Repo Packet Example"},
        {"examples/claude_packet/README.md",
         filename: "example-claude", title: "Claude Packet Example"},
        {"examples/simulated_recovery_packet/README.md",
         filename: "example-simulated-recovery", title: "Simulated Recovery Packet Example"},
        {"examples/multi_repo_packet/README.md",
         filename: "example-multi-repo", title: "Multi-Repo Packet Example"}
      ],
      groups_for_extras: [
        Overview: ["readme", "getting-started", "from-adrs-to-packets"],
        Authoring: [
          "cli",
          "configuration",
          "templates",
          "profiles",
          "multi-repo",
          "linting"
        ],
        Configuration: [
          "configuration",
          "providers",
          "simulated-provider",
          "verification-and-repair",
          "rendering"
        ],
        Operations: ["supervision", "workspaces", "control", "agent-control"],
        Embedding: ["api"],
        Architecture: ["architecture"],
        Examples: [
          "examples",
          "example-authoring",
          "example-single-repo",
          "example-claude",
          "example-simulated-recovery",
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
          PromptRunner.CompletionPolicy,
          PromptRunner.AgentControl,
          PromptRunner.PacketLint,
          PromptRunner.Packets,
          PromptRunner.Profile,
          PromptRunner.Verifier,
          PromptRunner.Verifier.Doc,
          PromptRunner.Verifier.ReposClean,
          PromptRunner.Watch,
          PromptRunner.RecoveryConfig,
          PromptRunner.FailureEnvelope,
          PromptRunner.RecoveryPolicy,
          PromptRunner.Runtime,
          PromptRunner.Run,
          PromptRunner.RunSpec,
          PromptRunner.Plan,
          PromptRunner.Preflight,
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
          PromptRunner.SimulatedLLM,
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
          PromptRunner.Template,
          PromptRunner.PermissionMode,
          PromptRunner.ProviderOptions
        ],
        "LLM Integration": [
          PromptRunner.LLM,
          PromptRunner.LLMFacade,
          PromptRunner.Session
        ],
        Observability: [
          PromptRunner.Control,
          PromptRunner.Control.Snapshot,
          PromptRunner.Control.Entry,
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
      files: ~w(
          lib
          priv
          guides
          assets
          mix.exs
          README.md
          CHANGELOG.md
          LICENSE
          run_prompts.exs
          examples/README.md
          examples/*_packet/README.md
          examples/*_packet/setup.sh
          examples/*_packet/cleanup.sh
          examples/*_packet/prompt_runner_packet.md
          examples/*_packet/prompts/*.prompt.md
          examples/*_packet/prompts/*.checklist.md
          examples/authoring_packet/docs/*.md
          examples/authoring_packet/templates/*.md
        ),
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "GitHub" => @source_url,
        "Hex" => @homepage_url,
        "HexDocs" => @docs_url,
        "License" => "#{@source_url}/blob/main/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end
end
