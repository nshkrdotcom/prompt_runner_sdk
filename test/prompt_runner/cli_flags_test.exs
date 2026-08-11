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
    assert output =~ "Selected: 1 (01)"
  end

  test "verify runs contracts without opening a provider or mutating progress", %{
    packet_root: packet_root
  } do
    output = capture_io(fn -> assert :ok = CLI.main(["verify", packet_root, "01", "--json"]) end)
    report = Jason.decode!(output)

    assert report["pass?"]
    assert report["prompts"] == 1
    assert report["failures"] == 0
    assert report["faults"] == 0
    refute File.exists?(Path.join(packet_root, ".prompt_runner/progress.log"))
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

  # `run PACKET --remaining` used to be `--remaining` reaching nothing: with no
  # prompt ids the CLI set `all: true`, and `build_targets/3` reached `:all`
  # before it ever looked at `:remaining`.
  test "run --remaining selects only unfinished prompts", %{packet_root: packet_root} do
    progress = Path.join([packet_root, ".prompt_runner", "progress.log"])
    File.mkdir_p!(Path.dirname(progress))
    File.write!(progress, "01:completed:2026-08-10T00:00:00Z:abc1234\n")

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "run",
                   packet_root,
                   "--remaining",
                   "--dry-run",
                   "--provider",
                   "simulated"
                 ])
      end)

    refute output =~ "[DRY RUN] Prompt 01"
  end

  test "run --remaining still selects a prompt that has not completed", %{
    packet_root: packet_root
  } do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "run",
                   packet_root,
                   "--remaining",
                   "--dry-run",
                   "--provider",
                   "simulated"
                 ])
      end)

    assert output =~ "[DRY RUN] Prompt 01"
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

  test "run and plan reject unknown switches instead of silently discarding them" do
    assert {:error, {:invalid_options, invalid}} =
             CLI.parse_run_options(["--remainging", "packet"])

    assert [{"--remainging", nil}] = invalid
  end

  test "keep-going is a declared run switch" do
    assert {:ok, opts, ["packet"]} = CLI.parse_run_options(["packet", "--keep-going"])
    assert opts[:keep_going]
  end

  test "from and through are strict declared run switches" do
    assert {:ok, opts, ["packet"]} =
             CLI.parse_run_options(["packet", "--from", "2", "--through", "17"])

    assert opts[:from] == "2"
    assert opts[:through] == "17"
  end
end
