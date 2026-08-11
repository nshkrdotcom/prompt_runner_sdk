defmodule PromptRunner.PacketLintCLITest do
  @moduledoc """
  CLI surface for `packet lint`. The exit-code path is covered at the
  `PromptRunner.PacketLint` level, since a non-zero exit halts the VM.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.CLI
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_lint_cli_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_lint_cli_repo")

    root =
      FSHelpers.packet!(
        "prompt_runner_lint_cli_packet",
        """
        ---
        name: "lint-cli"
        profile: "codex-default"
        repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Lint CLI Packet
        """,
        [
          {"01_write.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Write notes"
           targets:
             - "app"
           references:
             - "docs/adr-001.md"
           verify:
             files_exist:
               - "NOTES.md"
             commands:
               - "timeout 60 test -f NOTES.md"
           ---
           # Write notes
           """}
        ]
      )

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(repo)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "packet lint prints findings and exits zero when only warnings remain", %{root: root} do
    output = capture_io(fn -> assert :ok = CLI.main(["packet", "lint", root]) end)

    assert output =~ "WARNING"
    assert output =~ "inert_front_matter_key"
    assert output =~ "2 warnings"
  end

  test "packet lint --json prints a machine-readable report", %{root: root} do
    output = capture_io(fn -> assert :ok = CLI.main(["packet", "lint", root, "--json"]) end)

    report = Jason.decode!(output)

    assert report["packet"] == "lint-cli"
    assert report["pass?"] == true
    assert report["warnings"] == 2

    assert Enum.map(report["findings"], & &1["kind"]) == [
             "inert_front_matter_key",
             "legacy_shell_command"
           ]
  end

  test "packet lint is listed in the help output" do
    output = capture_io(fn -> assert :ok = CLI.main(["help"]) end)

    assert output =~ "packet lint"
  end
end
