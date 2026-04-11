defmodule PromptRunner.SimulatedRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner
  alias PromptRunner.Packet
  alias PromptRunner.Profile
  alias PromptRunner.Run
  alias PromptRunner.Runner
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_simulated_home")
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

  test "simulated provider automatically retries after transient capacity" do
    %{packet_root: packet_root, repo: repo} = simulated_packet_fixture("retry-packet")

    write_prompt(
      packet_root,
      "01_retry.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Retry prompt"
      targets:
        - "app"
      commit: "docs: retry"
      simulate:
        attempts:
          - error:
              kind: "provider_capacity"
              message: "Selected model is at capacity. Please try again."
          - writes:
              - path: "retry.txt"
                text: "retry ok"
      verify:
        files_exist:
          - "retry.txt"
        contains:
          - path: "retry.txt"
            text: "retry ok"
        changed_paths_only:
          - "retry.txt"
      ---
      # Retry prompt

      ## Mission

      Create `retry.txt`.
      """
    )

    assert {:ok, %Run{} = run} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert run.status == :ok
    assert File.read!(Path.join(repo, "retry.txt")) == "retry ok"

    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert prompt_status["status"] == "completed"
    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run", "retry"]
    assert Enum.map(prompt_status["attempts"], & &1["status"]) == ["failed", "completed"]
  end

  test "simulated provider automatically repairs unmet verifier items" do
    %{packet_root: packet_root, repo: repo} = simulated_packet_fixture("repair-packet")

    write_prompt(
      packet_root,
      "01_repair.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Repair prompt"
      targets:
        - "app"
      commit: "docs: repair"
      simulate:
        attempts:
          - writes:
              - path: "hello.txt"
                text: "hello"
          - writes:
              - path: "hello.meta.txt"
                text: "meta"
      verify:
        files_exist:
          - "hello.txt"
          - "hello.meta.txt"
        changed_paths_only:
          - "hello.txt"
          - "hello.meta.txt"
      ---
      # Repair prompt

      ## Mission

      Create `hello.txt` and `hello.meta.txt`.
      """
    )

    assert {:ok, %Run{} = run} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert run.status == :ok
    assert File.exists?(Path.join(repo, "hello.txt"))
    assert File.exists?(Path.join(repo, "hello.meta.txt"))

    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert prompt_status["status"] == "completed"
    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run", "repair"]

    assert Enum.map(prompt_status["attempts"], & &1["status"]) == [
             "verification_failed",
             "completed"
           ]
  end

  test "simulated provider resumes after recoverable transport failure" do
    %{packet_root: packet_root, repo: repo} = simulated_packet_fixture("resume-packet")

    write_prompt(
      packet_root,
      "01_resume.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Resume prompt"
      targets:
        - "app"
      commit: "docs: resume"
      simulate:
        attempts:
          - error:
              kind: "protocol_error"
              message: "WebSocket protocol error: Connection reset without closing handshake"
        resume:
          writes:
            - path: "resumed.txt"
              text: "resumed ok"
      verify:
        files_exist:
          - "resumed.txt"
        contains:
          - path: "resumed.txt"
            text: "resumed ok"
        changed_paths_only:
          - "resumed.txt"
      ---
      # Resume prompt

      ## Mission

      Create `resumed.txt`.
      """
    )

    assert {:ok, %Run{} = run} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert run.status == :ok
    assert File.read!(Path.join(repo, "resumed.txt")) == "resumed ok"

    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert prompt_status["status"] == "completed"
    assert length(prompt_status["attempts"]) == 1
    assert hd(prompt_status["attempts"])["mode"] == "run"
  end

  test "simulated provider reports built-in runtime info" do
    assert {:ok, info} = Runner.check_provider_runtime(:simulated)
    assert info.provider == :simulated
    assert info.lane == :builtin
    assert info.cli_command == "builtin"
  end

  defp simulated_packet_fixture(prefix) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_#{prefix}_packet")
    repo = FSHelpers.git_repo!("prompt_runner_#{prefix}_repo")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    assert {:ok, packet} =
             Packet.new(prefix,
               root: packet_root,
               profile: "simulated-default",
               provider: "simulated",
               model: "simulated-demo",
               permission_mode: "bypass",
               retry_attempts: 2,
               auto_repair: true
             )

    File.write!(
      packet.manifest_path,
      """
      ---
      name: "#{prefix}"
      profile: "simulated-default"
      provider: "simulated"
      model: "simulated-demo"
      permission_mode: "bypass"
      cli_confirmation: "off"
      retry_attempts: 2
      auto_repair: true
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Simulated Packet
      """
    )

    %{packet_root: packet.root, repo: repo}
  end

  defp write_prompt(packet_root, filename, body) do
    File.write!(Path.join([packet_root, "prompts", filename]), body)
  end
end
