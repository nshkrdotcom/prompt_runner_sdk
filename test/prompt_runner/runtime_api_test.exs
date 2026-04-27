defmodule PromptRunner.RuntimeAPITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias PromptRunner
  alias PromptRunner.Profile
  alias PromptRunner.Run
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_runtime_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    on_exit(fn ->
      Application.delete_env(:prompt_runner, :llm_module)

      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  test "packet run uses verifier-owned completion and auto repair" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_runtime_packet")
    repo = FSHelpers.git_repo!("prompt_runner_runtime_repo")
    on_exit(fn -> File.rm_rf!(packet_root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(
      Path.join(packet_root, "prompt_runner_packet.md"),
      """
      ---
      name: "runtime-packet"
      profile: "codex-default"
      cli_confirmation: "off"
      recovery:
        resume_attempts: 2
        retry:
          max_attempts: 0
          base_delay_ms: 0
          max_delay_ms: 0
          jitter: false
        repair:
          enabled: true
          max_attempts: 2
          trigger_on_nominal_success_with_failed_verifier: true
          trigger_on_provider_failure_with_workspace_changes: true
          trigger_on_retry_exhaustion_with_workspace_changes: true
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Runtime Packet
      """
    )

    File.write!(
      Path.join(packet_root, "prompts/01_repair.prompt.md"),
      """
      ---
      id: "01"
      phase: 1
      name: "Create hello"
      targets:
        - "app"
      commit: "chore: create hello"
      verify:
        files_exist:
          - "hello.txt"
          - "hello.meta.txt"
      ---
      # Create hello

      ## Mission

      Create `hello.txt` with one line: hello
      """
    )

    PromptRunner.LLMMock
    |> expect(:start_stream, 2, fn llm, prompt ->
      if String.contains?(prompt, "Repair Instructions") do
        File.write!(Path.join(llm.cwd, "hello.meta.txt"), "meta\n")
      else
        File.write!(Path.join(llm.cwd, "hello.txt"), "hello\n")
      end

      stream = [
        %{type: :run_started, data: %{model: llm.model}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert {:ok, %Run{} = run} =
             capture_io(fn ->
               send(
                 self(),
                 {:run_result,
                  PromptRunner.run(packet_root,
                    runtime_store: :memory,
                    committer: :noop
                  )}
               )
             end)
             |> then(fn _ ->
               assert_receive {:run_result, result}
               result
             end)

    assert run.status == :ok
    assert File.exists?(Path.join(repo, "hello.txt"))
    assert File.exists?(Path.join(repo, "hello.meta.txt"))

    assert {:ok, status} = PromptRunner.status(packet_root)
    assert status["prompts"]["01"]["status"] == "completed"
  end

  test "packet run fails preflight before invoking provider when target repo is missing" do
    packet_root = FSHelpers.tmp_dir("prompt_runner_runtime_packet")
    missing_repo = Path.join(packet_root, "repos/missing")
    on_exit(fn -> File.rm_rf!(packet_root) end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(
      Path.join(packet_root, "prompt_runner_packet.md"),
      """
      ---
      name: "runtime-packet"
      profile: "codex-default"
      cli_confirmation: "off"
      repos:
        app:
          path: "#{missing_repo}"
          default: true
      ---
      # Runtime Packet
      """
    )

    File.write!(
      Path.join(packet_root, "prompts/01_missing.prompt.md"),
      """
      ---
      id: "01"
      phase: 1
      name: "Missing repo"
      targets:
        - "app"
      commit: "chore: missing repo"
      verify:
        files_exist:
          - "hello.txt"
      ---
      # Missing repo

      ## Mission

      Create `hello.txt`.
      """
    )

    assert {:error, {:preflight_failed, report}} =
             capture_io(fn ->
               send(
                 self(),
                 {:run_result,
                  PromptRunner.run(packet_root,
                    runtime_store: :memory,
                    committer: :noop
                  )}
               )
             end)
             |> then(fn _ ->
               assert_receive {:run_result, result}
               result
             end)

    assert report.runtime_ready? == false
    assert [%{kind: "path_not_found", path: ^missing_repo}] = report.readiness_errors
  end
end
