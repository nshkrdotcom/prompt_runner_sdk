defmodule PromptRunner.PlanPrecedenceTest do
  @moduledoc """
  Option precedence across the resolution chain.

  The chain is defaults -> env -> global profile -> local config -> packet
  metadata -> call opts, and a later layer must always win.

  Regression coverage for a silent-override defect: packet metadata arrives with
  string keys and call/CLI options with atom keys, so before the fix both
  survived the deep merge as distinct keys and normalization-after-merge let the
  packet's string key win. A `run --provider simulated` against a packet whose
  manifest said `provider: "claude"` therefore started a live Claude session.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_precedence_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    root = FSHelpers.tmp_dir("prompt_runner_precedence_root")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(root, "prompts"))
    File.mkdir_p!(workspace)
    {_out, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)

    File.write!(Path.join(root, "prompt_runner_packet.md"), """
    ---
    name: "precedence"
    profile: "simulated-default"
    provider: "claude"
    model: "opus"
    reasoning_effort: "xhigh"
    permission_mode: "bypass"
    cli_confirmation: "off"
    claude_opts:
      include_thinking: false
    repos:
      app:
        path: "./workspace"
        default: true
    ---
    # Precedence packet
    """)

    File.write!(Path.join([root, "prompts", "01_noop.prompt.md"]), """
    ---
    id: "01"
    phase: 1
    name: "Noop"
    targets:
      - "app"
    verify:
      files_exist:
        - "NOPE.txt"
    ---
    # Noop
    """)

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "packet metadata overrides the profile", %{root: root} do
    assert {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    # simulated-default profile says simulated; the packet manifest says claude.
    assert plan.config.llm_sdk == :claude
    assert plan.config.model == "opus"
  end

  test "call options override packet metadata", %{root: root} do
    assert {:ok, plan} =
             PromptRunner.plan(root,
               interface: :cli,
               provider: "simulated",
               model: "simulated-demo"
             )

    assert plan.config.llm_sdk == :simulated
    assert plan.config.model == "simulated-demo"
  end

  test "a call option overrides only the key it names", %{root: root} do
    assert {:ok, plan} = PromptRunner.plan(root, interface: :cli, model: "haiku")

    assert plan.config.llm_sdk == :claude
    assert plan.config.model == "haiku"
  end

  test "packet-only keys survive a partial call override", %{root: root} do
    assert {:ok, plan} = PromptRunner.plan(root, interface: :cli, model: "haiku")

    assert plan.config.permission_mode == :bypass
    # cli_confirmation is carried as authored and normalized at launch, not here.
    assert plan.config.cli_confirmation == "off"
    assert plan.config.claude_opts["include_thinking"] == false
  end
end
