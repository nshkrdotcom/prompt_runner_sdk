defmodule PromptRunner.CLIFlagsTest do
  @moduledoc """
  Flag-surface coverage for `plan` and `run`.

  `plan` parsed no flags at all and passed none to `PromptRunner.plan/2`, so
  `prompt_runner plan --provider X` reported the packet's provider regardless
  and could not be used to check what an override would do. `run` honoured
  `opts[:dry_run]` in the runner but no CLI switch reached it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.CLI
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_cli_flags_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    packet_root = FSHelpers.tmp_dir("prompt_runner_cli_flags_packet")
    repo = FSHelpers.git_repo!("prompt_runner_cli_flags_repo")
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "flags"
    profile: "simulated-default"
    provider: "claude"
    model: "opus"
    permission_mode: "bypass"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Flags packet
    """)

    File.write!(Path.join([packet_root, "prompts", "01_noop.prompt.md"]), """
    ---
    id: "01"
    phase: 1
    name: "Noop"
    targets:
      - "app"
    verify:
      files_exist:
        - "README.md"
    ---
    # Noop

    ## Mission

    Do nothing.
    """)

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    {:ok, packet_root: packet_root, repo: repo}
  end

  test "plan reports the packet provider when no override is given", %{packet_root: packet_root} do
    output = capture_io(fn -> assert :ok = CLI.main(["plan", packet_root]) end)

    assert output =~ "Provider: claude"
    assert output =~ "Model: opus"
  end

  test "plan applies the same overrides run does", %{packet_root: packet_root} do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "plan",
                   packet_root,
                   "--provider",
                   "simulated",
                   "--model",
                   "simulated-demo"
                 ])
      end)

    assert output =~ "Provider: simulated"
    assert output =~ "Model: simulated-demo"
    refute output =~ "Provider: claude"
  end

  test "run --dry-run describes the prompt without starting a provider", %{
    packet_root: packet_root
  } do
    output =
      capture_io(fn ->
        assert :ok = CLI.main(["run", packet_root, "--dry-run", "--provider", "simulated"])
      end)

    assert output =~ "[DRY RUN] Prompt 01"
    assert output =~ "LLM provider: simulated"
    refute output =~ "Starting simulated session"
    refute File.exists?(Path.join([packet_root, ".prompt_runner", "logs"]))
  end

  test "run --dry-run honours --no-commit in the plan preview", %{packet_root: packet_root} do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "run",
                   packet_root,
                   "--dry-run",
                   "--no-commit",
                   "--provider",
                   "simulated"
                 ])
      end)

    assert output =~ "SKIPPED (--no-commit)"
  end
end
