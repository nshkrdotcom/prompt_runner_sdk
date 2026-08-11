defmodule PromptRunner.RepairPromptTest do
  @moduledoc """
  What a repair attempt actually says to the model.

  The failures block was `inspect/1` of an Elixir map, so a model asked to
  repair a prompt received `%{"command" => "mix test", "details" => "...\\n..."}`
  — the command output's newlines escaped into a single line, inside a data
  structure from a language the model was not being asked to read.
  """

  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_repair_home")
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

  defp packet!(state) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_repair_packet")
    repo = FSHelpers.git_repo!("prompt_runner_repair_repo")

    on_exit(fn ->
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))
    File.mkdir_p!(Path.join(packet_root, ".prompt_runner"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "repair-packet"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Repair packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_step.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Step 01"
    targets:
      - "app"
    verify:
      files_exist:
        - "README.md"
    ---
    # Original body
    """)

    File.write!(
      Path.join([packet_root, ".prompt_runner", "state.json"]),
      Jason.encode!(%{"version" => 1, "prompts" => %{"01" => state}})
    )

    packet_root
  end

  defp capture_repair_prompt(packet_root) do
    test_pid = self()

    expect(PromptRunner.LLMMock, :start_stream, fn llm, prompt ->
      send(test_pid, {:prompt, prompt})

      stream = [
        %{type: :run_started, data: %{model: llm.model}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    ExUnit.CaptureIO.capture_io(fn ->
      send(test_pid, {:result, PromptRunner.repair(packet_root, prompt: "01", no_commit: true)})
    end)

    assert_receive {:prompt, prompt}
    assert_receive {:result, _result}
    prompt
  end

  test "a failure renders as labelled fields and readable output, not an Elixir map" do
    packet_root =
      packet!(%{
        "last_error" => "boom",
        "last_verifier" => %{
          "failures" => [
            %{
              "kind" => "command",
              "repo" => "app",
              "command" => "timeout 60 mix test",
              "cwd" => "/tmp/app",
              "details" =>
                "1) test truth\n   Assertion failed\n2) test other\n   Assertion failed"
            }
          ]
        }
      })

    prompt = capture_repair_prompt(packet_root)

    assert prompt =~ "# Original body"
    assert prompt =~ "kind: command"
    assert prompt =~ "repo: app"
    assert prompt =~ "command: timeout 60 mix test"
    assert prompt =~ "cwd: /tmp/app"
    assert prompt =~ "1) test truth"
    assert prompt =~ "2) test other"

    refute prompt =~ ~s(%{")
    refute prompt =~ "\\n"
  end

  test "an absent field is omitted rather than rendered as nil" do
    packet_root =
      packet!(%{
        "last_verifier" => %{
          "failures" => [
            %{"kind" => "file_exists", "path" => "lib/thing.ex", "details" => "missing"}
          ]
        }
      })

    prompt = capture_repair_prompt(packet_root)

    assert prompt =~ "kind: file_exists"
    assert prompt =~ "path: lib/thing.ex"
    refute prompt =~ "repo:"
    refute prompt =~ "command:"
  end

  test "long output is truncated with an explicit marker rather than silently" do
    details = Enum.map_join(1..120, "\n", &"line #{&1}")

    packet_root =
      packet!(%{
        "last_verifier" => %{
          "failures" => [%{"kind" => "command", "command" => "mix test", "details" => details}]
        }
      })

    prompt = capture_repair_prompt(packet_root)

    assert prompt =~ "line 1"
    assert prompt =~ "line 40"
    refute prompt =~ "line 41\n"
    assert prompt =~ "[truncated: 80 more lines]"
  end

  test "no recorded failures says so instead of rendering an empty list" do
    packet_root = packet!(%{"last_verifier" => %{"failures" => []}})

    prompt = capture_repair_prompt(packet_root)

    assert prompt =~ "(none recorded)"
  end
end
