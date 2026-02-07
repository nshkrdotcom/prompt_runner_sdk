defmodule PromptRunner.ValidatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PromptRunner.Config
  alias PromptRunner.Validator

  defp write_config!(tmp_dir, config) do
    config_path = Path.join(tmp_dir, "runner_config.exs")
    File.write!(config_path, config)
    config_path
  end

  test "validate_all expands repo groups in prompt target_repos" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "prompt_runner_validator_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command_dir = Path.join(tmp_dir, "command")
    flowstone_dir = Path.join(tmp_dir, "flowstone")
    File.mkdir_p!(command_dir)
    File.mkdir_p!(flowstone_dir)

    File.write!(Path.join(tmp_dir, "001.md"), "hello\n")
    File.write!(Path.join(tmp_dir, "prompts.txt"), "01|1|1|Alpha|001.md|@pipeline\n")

    File.write!(
      Path.join(tmp_dir, "commit-messages.txt"),
      """
      === COMMIT 01:command ===
      test(command): message

      === COMMIT 01:flowstone ===
      test(flowstone): message
      """
    )

    config_path =
      write_config!(
        tmp_dir,
        """
        %{
          project_dir: "#{command_dir}",
          target_repos: [
            %{name: "command", path: "#{command_dir}", default: true},
            %{name: "flowstone", path: "#{flowstone_dir}"}
          ],
          repo_groups: %{
            "pipeline" => ["command", "flowstone"]
          },
          prompts_file: "prompts.txt",
          commit_messages_file: "commit-messages.txt",
          progress_file: ".progress",
          log_dir: "logs",
          model: "haiku",
          llm: %{sdk: "claude_agent_sdk"}
        }
        """
      )

    {:ok, config} = Config.load(config_path)

    capture_io(fn ->
      assert :ok = Validator.validate_all(config)
    end)
  end

  test "validate_all accepts repo-specific commit message for default repo when prompt has no target_repos" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "prompt_runner_validator_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command_dir = Path.join(tmp_dir, "command")
    File.mkdir_p!(command_dir)

    File.write!(Path.join(tmp_dir, "001.md"), "hello\n")
    File.write!(Path.join(tmp_dir, "prompts.txt"), "01|1|1|Alpha|001.md\n")

    File.write!(
      Path.join(tmp_dir, "commit-messages.txt"),
      """
      === COMMIT 01:command ===
      test(command): message
      """
    )

    config_path =
      write_config!(
        tmp_dir,
        """
        %{
          project_dir: "#{command_dir}",
          target_repos: [
            %{name: "command", path: "#{command_dir}", default: true}
          ],
          prompts_file: "prompts.txt",
          commit_messages_file: "commit-messages.txt",
          progress_file: ".progress",
          log_dir: "logs",
          model: "haiku",
          llm: %{sdk: "claude_agent_sdk"}
        }
        """
      )

    {:ok, config} = Config.load(config_path)

    capture_io(fn ->
      assert :ok = Validator.validate_all(config)
    end)
  end

  test "validate_all reports unknown repo groups" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "prompt_runner_validator_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command_dir = Path.join(tmp_dir, "command")
    File.mkdir_p!(command_dir)

    File.write!(Path.join(tmp_dir, "001.md"), "hello\n")
    File.write!(Path.join(tmp_dir, "prompts.txt"), "01|1|1|Alpha|001.md|@missing\n")
    File.write!(Path.join(tmp_dir, "commit-messages.txt"), "")

    config_path =
      write_config!(
        tmp_dir,
        """
        %{
          project_dir: "#{command_dir}",
          target_repos: [
            %{name: "command", path: "#{command_dir}", default: true}
          ],
          repo_groups: %{},
          prompts_file: "prompts.txt",
          commit_messages_file: "commit-messages.txt",
          progress_file: ".progress",
          log_dir: "logs",
          model: "haiku",
          llm: %{sdk: "claude_agent_sdk"}
        }
        """
      )

    {:ok, config} = Config.load(config_path)

    capture_io(fn ->
      assert {:error, errors} = Validator.validate_all(config)

      assert Enum.any?(errors, fn {num, _repo, msg} ->
               num == "01" and msg == "Unknown repo group: @missing"
             end)
    end)
  end
end
