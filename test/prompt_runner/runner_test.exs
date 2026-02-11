defmodule PromptRunner.RunnerTest do
  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Config
  alias PromptRunner.Progress
  alias PromptRunner.Runner

  setup :verify_on_exit!

  test "runs a prompt and records progress" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_runner_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "001.md"), "hello\n")
    File.write!(Path.join(tmp_dir, "prompts.txt"), "01|1|1|Alpha|001.md\n")

    File.write!(
      Path.join(tmp_dir, "commit-messages.txt"),
      "=== COMMIT 01 ===\nchore: demo\n"
    )

    config_path = Path.join(tmp_dir, "runner_config.exs")

    File.write!(
      config_path,
      """
      %{
        project_dir: "#{tmp_dir}",
        prompts_file: "prompts.txt",
        commit_messages_file: "commit-messages.txt",
        progress_file: ".progress",
        log_dir: "logs",
        model: "haiku",
        llm: %{provider: "claude"}
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{type: :run_started, data: %{model: llm.model}},
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert :ok = Runner.run(config, [run: true, no_commit: true], ["01"])

    statuses = Progress.statuses(config)
    assert statuses["01"].status == "completed"
  end

  test "returns error and marks progress failed when streaming/rendering raises" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_runner_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "001.md"), "hello\n")
    File.write!(Path.join(tmp_dir, "prompts.txt"), "01|1|1|Alpha|001.md\n")

    File.write!(
      Path.join(tmp_dir, "commit-messages.txt"),
      "=== COMMIT 01 ===\nchore: demo\n"
    )

    config_path = Path.join(tmp_dir, "runner_config.exs")

    File.write!(
      config_path,
      """
      %{
        project_dir: "#{tmp_dir}",
        prompts_file: "prompts.txt",
        commit_messages_file: "commit-messages.txt",
        progress_file: ".progress",
        log_dir: "logs",
        model: "haiku",
        llm: %{provider: "claude"}
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      # This malformed event has no :type key and will raise inside renderer.
      stream = [%{type: :run_started, data: %{model: llm.model}}, %URI{path: "x"}]
      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert {:error, {:stream_failed, _}} =
             Runner.run(config, [run: true, no_commit: true], ["01"])

    statuses = Progress.statuses(config)
    assert statuses["01"].status == "failed"
  end
end
