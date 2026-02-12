defmodule PromptRunner.RunnerTest do
  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner.Config
  alias PromptRunner.Progress
  alias PromptRunner.Runner

  setup :verify_on_exit!

  defp run_quiet(fun) when is_function(fun, 0) do
    ExUnit.CaptureIO.capture_io(fn ->
      send(self(), {:runner_result, fun.()})
    end)

    assert_receive {:runner_result, result}
    result
  end

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

    assert :ok = run_quiet(fn -> Runner.run(config, [run: true, no_commit: true], ["01"]) end)

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

    ExUnit.CaptureIO.capture_io(fn ->
      assert {:error, {:stream_failed, _}} =
               Runner.run(config, [run: true, no_commit: true], ["01"])
    end)

    statuses = Progress.statuses(config)
    assert statuses["01"].status == "failed"
  end

  test "preserves provider_error from stream error events" do
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
        model: "gpt-5.3-codex",
        llm: %{provider: "codex"}
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{type: :run_started, data: %{model: llm.model, metadata: %{}}},
        %{
          type: :error_occurred,
          data: %{
            error_message: "legacy error message",
            provider_error: %{
              provider: :codex,
              kind: :transport_exit,
              message: "codex executable exited with status 2",
              exit_code: 2,
              stderr: "permission denied",
              truncated?: false
            }
          }
        }
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert {:error, %{message: message, provider_error: provider_error}} =
             run_quiet(fn -> Runner.run(config, [run: true, no_commit: true], ["01"]) end)

    assert message == "codex executable exited with status 2"
    assert provider_error.provider == :codex
    assert provider_error.kind == :transport_exit
    assert provider_error.exit_code == 2
  end

  test "prints provider stderr details only when log_meta is full" do
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
        model: "gpt-5.3-codex",
        log_meta: :full,
        llm: %{provider: "codex"}
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{type: :run_started, data: %{model: llm.model, metadata: %{}}},
        %{
          type: :run_failed,
          data: %{
            error_message: "legacy error message",
            provider_error: %{
              provider: :codex,
              kind: :transport_exit,
              message: "codex executable exited with status 2",
              exit_code: 2,
              stderr: "permission denied\nmissing auth token",
              truncated?: true
            }
          }
        }
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, %{provider_error: provider_error}} =
                 Runner.run(config, [run: true, no_commit: true], ["01"])

        assert provider_error.stderr =~ "missing auth token"
      end)

    assert output =~ "ERROR: codex executable exited with status 2"
    assert output =~ "stderr:"
    assert output =~ "permission denied"
  end

  test "uses studio renderer and respects --tool-output override" do
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
        log_mode: :studio,
        tool_output: :summary,
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
        %{
          type: :tool_call_started,
          data: %{
            tool_name: "Read",
            tool_call_id: "tu_001",
            tool_input: %{"file_path" => "mix.exs"}
          }
        },
        %{
          type: :tool_call_completed,
          data: %{
            tool_name: "Read",
            tool_call_id: "tu_001",
            tool_input: %{"file_path" => "mix.exs"},
            tool_output: "line1\nline2\nline3\n"
          }
        },
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Runner.run(config, [run: true, no_commit: true, tool_output: "full"], ["01"])
      end)

    plain = String.replace(output, ~r/\x1b\[[0-9;]*m/, "")

    assert plain =~ "Prompt 01: Alpha"
    assert plain =~ "Session complete"
    assert plain =~ "┊ line1"
    assert plain =~ "  ✓ Prompt 01 completed"
  end

  test "prints configured and CLI-confirmed codex model/reasoning" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          codex_thread_opts: %{reasoning_effort: :xhigh}
        }
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{
          type: :run_started,
          data: %{
            model: llm.model,
            metadata: %{
              "model" => llm.model,
              "config" => %{"model_reasoning_effort" => "xhigh"}
            }
          }
        },
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Runner.run(config, [run: true, no_commit: true], ["01"])
      end)

    assert output =~ "LLM: codex model=gpt-5.3-codex reasoning=xhigh (configured)"
    assert output =~ "LLM confirmed (codex_cli): model=gpt-5.3-codex reasoning=xhigh"
  end

  test "prints warning when codex CLI confirmation does not include reasoning" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          codex_thread_opts: %{reasoning_effort: :xhigh}
        }
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{
          type: :run_started,
          data: %{
            model: llm.model,
            metadata: %{"model" => llm.model}
          }
        },
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Runner.run(config, [run: true, no_commit: true], ["01"])
      end)

    assert output =~ "LLM: codex model=gpt-5.3-codex reasoning=xhigh (configured)"
    assert output =~ "WARNING: codex_cli confirmation missing reasoning_effort"
  end

  test "prints mismatch warning when configured and confirmed codex settings differ" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          codex_thread_opts: %{reasoning_effort: :xhigh}
        }
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{
          type: :run_started,
          data: %{
            model: llm.model,
            metadata: %{
              "model" => llm.model,
              "config" => %{"model_reasoning_effort" => "medium"}
            }
          }
        },
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Runner.run(config, [run: true, no_commit: true], ["01"])
      end)

    assert output =~ "WARNING: codex_cli confirmation mismatch"
    assert output =~ "configured_reasoning=xhigh"
    assert output =~ "confirmed_reasoning=medium"
  end

  test "fails when --require-cli-confirmation is enabled and codex reasoning is not confirmed" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          codex_thread_opts: %{reasoning_effort: :xhigh}
        }
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{type: :run_started, data: %{model: llm.model, metadata: %{"model" => llm.model}}},
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    captured_result =
      ExUnit.CaptureIO.capture_io(fn ->
        result =
          Runner.run(config, [run: true, no_commit: true, cli_confirmation: "require"], ["01"])

        send(self(), {:captured_result, result})
      end)

    assert is_binary(captured_result)
    assert_receive {:captured_result, {:error, {:cli_confirmation_missing, details}}}

    assert details.configured_model == "gpt-5.3-codex"
    assert details.configured_reasoning == "xhigh"
    assert details.confirmed_reasoning == nil

    statuses = Progress.statuses(config)
    assert statuses["01"].status == "failed"
  end

  test "writes machine-readable codex audit lines to session log" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          codex_thread_opts: %{reasoning_effort: :xhigh}
        }
      }
      """
    )

    {:ok, config} = Config.load(config_path)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, _prompt ->
      stream = [
        %{
          type: :run_started,
          data: %{
            model: llm.model,
            metadata: %{
              "model" => llm.model,
              "config" => %{"model_reasoning_effort" => "xhigh"}
            }
          }
        },
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert :ok = run_quiet(fn -> Runner.run(config, [run: true, no_commit: true], ["01"]) end)

    [log_path] = Path.wildcard(Path.join(tmp_dir, "logs/prompt-01-*.log"))
    log_text = File.read!(log_path)

    assert log_text =~ "LLM_AUDIT configured_model=gpt-5.3-codex configured_reasoning=xhigh"

    assert log_text =~
             "LLM_AUDIT_RESULT status=matched configured_model=gpt-5.3-codex configured_reasoning=xhigh confirmed_model=gpt-5.3-codex confirmed_reasoning=xhigh"
  end

  describe "check_provider_dependency/1" do
    test "returns ok with info for :claude" do
      assert {:ok, %{package: "claude_agent_sdk", module: "ClaudeAgentSDK"}} =
               Runner.check_provider_dependency(:claude)
    end

    test "returns ok with info for :codex" do
      assert {:ok, %{package: "codex_sdk", module: "Codex"}} =
               Runner.check_provider_dependency(:codex)
    end

    test "returns ok with info for :amp" do
      assert {:ok, %{package: "amp_sdk", module: "AmpSdk"}} =
               Runner.check_provider_dependency(:amp)
    end

    test "returns ok nil for unknown provider" do
      assert {:ok, nil} = Runner.check_provider_dependency(:unknown_provider)
    end
  end
end
