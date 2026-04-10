defmodule PromptRunner.VerifierTest do
  use ExUnit.Case, async: false

  alias PromptRunner
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_verifier_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  test "verify_prompt evaluates files and commands" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_verifier_packet")
    repo = FSHelpers.git_repo!("prompt_runner_verifier_repo")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(
      Path.join(packet_root, "prompt_runner_packet.md"),
      """
      ---
      name: "verifier-packet"
      profile: "codex-default"
      repos:
        app:
          path: "#{repo}"
          default: true
      phases:
        1: "Verification"
      ---
      # Verifier Packet
      """
    )

    File.write!(
      Path.join(packet_root, "prompts/01_verify.prompt.md"),
      """
      ---
      id: "01"
      phase: 1
      name: "Verify repo"
      targets:
        - "app"
      commit: "chore: verify"
      verify:
        files_exist:
          - "README.md"
        files_absent:
          - "missing.txt"
        contains:
          - path: "README.md"
            text: "# Repo"
        commands:
          - "test -f README.md"
      ---
      # Verify repo
      """
    )

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    prompt = hd(plan.prompts)
    report = Verifier.verify_prompt(plan, prompt)

    assert report.pass?
    assert report.failures == []
  end

  test "changed_paths_only uses the prompt default repo when entries omit repo" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_verifier_packet")
    repo = FSHelpers.git_repo!("prompt_runner_verifier_repo")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))
    File.write!(Path.join(repo, "hello.txt"), "hello\n")

    File.write!(
      Path.join(packet_root, "prompt_runner_packet.md"),
      """
      ---
      name: "verifier-packet"
      profile: "codex-default"
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Verifier Packet
      """
    )

    File.write!(
      Path.join(packet_root, "prompts/01_verify.prompt.md"),
      """
      ---
      id: "01"
      phase: 1
      name: "Verify repo"
      targets:
        - "app"
      commit: "chore: verify"
      verify:
        changed_paths_only:
          - "hello.txt"
      ---
      # Verify repo
      """
    )

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    prompt = hd(plan.prompts)
    report = Verifier.verify_prompt(plan, prompt)

    assert report.pass?
    assert Enum.all?(report.items, & &1.pass?)
  end
end
