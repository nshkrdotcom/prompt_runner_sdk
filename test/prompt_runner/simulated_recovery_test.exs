defmodule PromptRunner.SimulatedRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner
  alias PromptRunner.FrontMatter
  alias PromptRunner.Packet
  alias PromptRunner.Profile
  alias PromptRunner.RecoveryConfig
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

  test "simulated provider retries remote auth claims before succeeding" do
    %{packet_root: packet_root, repo: repo} = simulated_packet_fixture("auth-retry-packet")

    write_prompt(
      packet_root,
      "01_auth_retry.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Retry remote auth claim"
      targets:
        - "app"
      commit: "docs: auth retry"
      simulate:
        attempts:
          - error:
              kind: "provider_auth_claim"
              message: "Provider reported an auth handshake failure."
          - writes:
              - path: "auth.txt"
                text: "auth ok"
      verify:
        files_exist:
          - "auth.txt"
        contains:
          - path: "auth.txt"
            text: "auth ok"
        changed_paths_only:
          - "auth.txt"
      ---
      # Retry auth claim
      """
    )

    assert {:ok, %Run{status: :ok}} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert File.read!(Path.join(repo, "auth.txt")) == "auth ok"
    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run", "retry"]
    assert Enum.map(prompt_status["attempts"], & &1["status"]) == ["failed", "completed"]
  end

  test "simulated provider retries config claims more than once before succeeding" do
    recovery =
      RecoveryConfig.default()
      |> put_in(["retry", "base_delay_ms"], 0)
      |> put_in(["retry", "max_delay_ms"], 0)
      |> put_in(["retry", "jitter"], false)
      |> put_in(["retry", "class_attempts", "provider_config_claim"], 2)

    %{packet_root: packet_root, repo: repo} =
      simulated_packet_fixture("config-retry-packet", recovery: recovery)

    write_prompt(
      packet_root,
      "01_config_retry.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Retry config claim"
      targets:
        - "app"
      commit: "docs: config retry"
      simulate:
        attempts:
          - error:
              kind: "provider_config_claim"
              message: "Selected model is temporarily unavailable."
          - error:
              kind: "provider_config_claim"
              message: "Selected model is temporarily unavailable."
          - writes:
              - path: "config.txt"
                text: "config ok"
      verify:
        files_exist:
          - "config.txt"
        contains:
          - path: "config.txt"
            text: "config ok"
        changed_paths_only:
          - "config.txt"
      ---
      # Retry config claim
      """
    )

    assert {:ok, %Run{status: :ok}} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert File.read!(Path.join(repo, "config.txt")) == "config ok"
    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run", "retry", "retry"]

    assert Enum.map(prompt_status["attempts"], & &1["status"]) == [
             "failed",
             "failed",
             "completed"
           ]
  end

  test "simulated provider completes when verification passes despite provider runtime error" do
    %{packet_root: packet_root, repo: repo} = simulated_packet_fixture("override-packet")

    write_prompt(
      packet_root,
      "01_override.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Verifier override"
      targets:
        - "app"
      commit: "docs: verifier override"
      simulate:
        attempts:
          - writes:
              - path: "override.txt"
                text: "override ok"
            error:
              kind: "provider_runtime_claim"
              message: "Final transport flush failed after writing output."
      verify:
        files_exist:
          - "override.txt"
        contains:
          - path: "override.txt"
            text: "override ok"
        changed_paths_only:
          - "override.txt"
      ---
      # Verifier override
      """
    )

    assert {:ok, %Run{status: :ok}} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert File.read!(Path.join(repo, "override.txt")) == "override ok"
    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert prompt_status["status"] == "completed"
    assert Enum.map(prompt_status["attempts"], & &1["status"]) == ["completed"]
  end

  test "simulated provider repairs after retry exhaustion when prompt-local recovery is tighter" do
    recovery =
      RecoveryConfig.default()
      |> put_in(["retry", "base_delay_ms"], 0)
      |> put_in(["retry", "max_delay_ms"], 0)
      |> put_in(["retry", "jitter"], false)

    %{packet_root: packet_root, repo: repo} =
      simulated_packet_fixture("retry-exhaust-repair-packet", recovery: recovery)

    write_prompt(
      packet_root,
      "01_retry_exhaust_repair.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Repair after retry exhaustion"
      targets:
        - "app"
      commit: "docs: repair after exhaustion"
      recovery:
        retry:
          class_attempts:
            provider_runtime_claim: 1
      simulate:
        attempts:
          - error:
              kind: "provider_runtime_claim"
              message: "Unexpected remote runtime failure."
          - writes:
              - path: "draft.txt"
                text: "draft"
            error:
              kind: "provider_runtime_claim"
              message: "Unexpected remote runtime failure."
          - writes:
              - path: "draft.meta.txt"
                text: "meta"
      verify:
        files_exist:
          - "draft.txt"
          - "draft.meta.txt"
        changed_paths_only:
          - "draft.txt"
          - "draft.meta.txt"
      ---
      # Repair after retry exhaustion
      """
    )

    assert {:ok, %Run{status: :ok}} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert File.read!(Path.join(repo, "draft.txt")) == "draft"
    assert File.read!(Path.join(repo, "draft.meta.txt")) == "meta"

    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]

    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run", "retry", "repair"]

    assert Enum.map(prompt_status["attempts"], & &1["status"]) == [
             "failed",
             "failed",
             "completed"
           ]
  end

  test "simulated provider fails fast on deterministic local failures" do
    %{packet_root: packet_root} = simulated_packet_fixture("local-fail-fast-packet")

    write_prompt(
      packet_root,
      "01_local_fail_fast.prompt.md",
      """
      ---
      id: "01"
      phase: 1
      name: "Fail fast on local deterministic error"
      targets:
        - "app"
      commit: "docs: local fail fast"
      simulate:
        attempts:
          - error:
              kind: "provider_runtime_claim"
              message: "Local configuration contradiction."
              recovery:
                class: "provider_config_claim"
                retryable?: true
                repairable?: false
                resumeable?: false
                remote_claim?: false
                local_deterministic?: true
      verify:
        files_exist:
          - "never-created.txt"
      ---
      # Fail fast
      """
    )

    assert {:error, _reason} =
             capture_io(fn ->
               send(self(), {:result, PromptRunner.run(packet_root, committer: :noop)})
             end)
             |> then(fn _ ->
               assert_receive {:result, result}
               result
             end)

    assert {:ok, status} = PromptRunner.status(packet_root)
    prompt_status = status["prompts"]["01"]
    assert prompt_status["status"] == "failed"
    assert Enum.map(prompt_status["attempts"], & &1["mode"]) == ["run"]
    assert Enum.map(prompt_status["attempts"], & &1["status"]) == ["failed"]
  end

  defp simulated_packet_fixture(prefix, opts \\ []) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_#{prefix}_packet")
    repo = FSHelpers.git_repo!("prompt_runner_#{prefix}_repo")

    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    recovery =
      opts[:recovery] ||
        RecoveryConfig.default()
        |> put_in(["retry", "base_delay_ms"], 0)
        |> put_in(["retry", "max_delay_ms"], 0)
        |> put_in(["retry", "jitter"], false)

    assert {:ok, packet} =
             Packet.new(prefix,
               root: packet_root,
               profile: "simulated-default",
               provider: "simulated",
               model: "simulated-demo",
               permission_mode: "bypass",
               recovery: recovery
             )

    :ok =
      FrontMatter.write_file(
        packet.manifest_path,
        %{
          "name" => prefix,
          "profile" => "simulated-default",
          "provider" => "simulated",
          "model" => "simulated-demo",
          "permission_mode" => "bypass",
          "cli_confirmation" => "off",
          "recovery" => recovery,
          "repos" => %{
            "app" => %{
              "path" => repo,
              "default" => true
            }
          }
        },
        "# Simulated Packet\n"
      )

    %{packet_root: packet.root, repo: repo}
  end

  defp write_prompt(packet_root, filename, body) do
    File.write!(Path.join([packet_root, "prompts", filename]), body)
  end
end
