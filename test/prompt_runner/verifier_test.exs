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

  test "structured commands preserve argv literally and resolve a child cwd" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_structured_verifier_packet")
    repo = FSHelpers.git_repo!("prompt_runner_structured_verifier_repo")
    child = Path.join(repo, "path with spaces")
    File.mkdir_p!(child)

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "structured-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Structured verifier
    """)

    marker = Path.join(repo, "SHOULD_NOT_EXIST")

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Structured command"
    targets: ["app"]
    verify:
      commands:
        - repo: app
          cwd: "path with spaces"
          exec: /usr/bin/printf
          args: ["%s", "literal; touch #{marker}"]
          timeout_ms: 2000
    ---
    # Structured command
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    assert report.pass?
    assert [item] = report.items
    assert item.mode == :structured
    assert item.cwd == child
    assert item.details == "literal; touch #{marker}"
    refute File.exists?(marker)
  end

  test "structured command argv resolves logical repository paths" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_logical_argv_packet")
    repo = FSHelpers.git_repo!("prompt_runner_logical_argv_repo")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))
    File.mkdir_p!(Path.join(repo, "nested"))
    File.write!(Path.join(repo, "nested/evidence.txt"), "evidence\n")

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "logical-argv-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Logical argv verifier
    """)

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Logical argv"
    targets: ["app"]
    verify:
      commands:
        - exec: /usr/bin/test
          args: ["-f", "@repo:app/nested/evidence.txt"]
    ---
    # Logical argv
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    assert report.pass?
    assert [%{mode: :structured, pass?: true}] = report.items
  end

  test "a structured command timeout is an infrastructure fault, not exit folklore" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_timeout_verifier_packet")
    repo = FSHelpers.git_repo!("prompt_runner_timeout_verifier_repo")
    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "timeout-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Timeout verifier
    """)

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Timeout"
    targets: ["app"]
    verify:
      commands:
        - repo: app
          exec: /bin/sleep
          args: ["2"]
          timeout_ms: 20
    ---
    # Timeout
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    refute report.pass?
    assert [fault] = report.faults
    assert fault.fault == :verifier_timeout
    assert fault.exit_code == nil
  end

  test "a missing prompt-produced executable fails work while a missing PATH tool faults" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_missing_executable_packet")
    repo = FSHelpers.git_repo!("prompt_runner_missing_executable_repo")
    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "missing-executable-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Missing executable verifier
    """)

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Missing executable"
    targets: ["app"]
    verify:
      commands:
        - repo: app
          exec: bin/future-product
          args: ["check"]
          timeout_ms: 2000
        - repo: app
          exec: prompt-runner-tool-that-does-not-exist
          args: ["check"]
          timeout_ms: 2000
    ---
    # Missing executable
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    refute report.pass?
    assert [path_failure, infrastructure_fault] = report.items
    assert path_failure.fault == nil
    assert path_failure.details =~ "bin/future-product"
    assert infrastructure_fault.fault == :verifier_fault
    assert report.faults == [infrastructure_fault]
  end

  test "regenerates cannot pass against a stale artifact and restores it on failure" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_regeneration_packet")
    repo = FSHelpers.git_repo!("prompt_runner_regeneration_repo")
    output = Path.join(repo, "figure.png")
    File.write!(output, "old")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "regeneration-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Regeneration verifier
    """)

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Regenerate"
    targets: ["app"]
    verify:
      commands:
        - exec: /usr/bin/true
          args: []
          regenerates: ["figure.png"]
          timeout_ms: 2000
    ---
    # Regenerate
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    refute report.pass?
    assert File.read!(output) == "old"
    refute File.exists?(output <> ".prompt-runner-verifier-backup")
  end

  test "regenerates requires and retains the freshly written artifact" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_regeneration_success_packet")
    repo = FSHelpers.git_repo!("prompt_runner_regeneration_success_repo")
    output = Path.join(repo, "figure.png")
    File.write!(output, "old")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "regeneration-success-verifier"
    profile: "codex-default"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Regeneration success verifier
    """)

    File.write!(Path.join(packet_root, "prompts/01_verify.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Regenerate"
    targets: ["app"]
    verify:
      commands:
        - exec: /usr/bin/python3
          args: ["-c", "from pathlib import Path; Path('figure.png').write_text('new')"]
          regenerates: ["figure.png"]
          timeout_ms: 2000
    ---
    # Regenerate
    """)

    assert {:ok, plan} = PromptRunner.plan(packet_root)
    report = Verifier.verify_prompt(plan, hd(plan.prompts))

    assert report.pass?
    assert File.read!(output) == "new"
    refute File.exists?(output <> ".prompt-runner-verifier-backup")
  end
end
