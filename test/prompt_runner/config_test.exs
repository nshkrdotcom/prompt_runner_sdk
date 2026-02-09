defmodule PromptRunner.ConfigTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Config
  alias PromptRunner.Prompt

  test "loads config and normalizes prompt overrides" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    prompts_path = Path.join(tmp_dir, "prompts.txt")
    commits_path = Path.join(tmp_dir, "commit-messages.txt")

    File.write!(prompts_path, "01|1|1|Alpha|001.md\n02|1|1|Beta|002.md\n")
    File.write!(commits_path, "=== COMMIT 01 ===\nmsg\n=== COMMIT 02 ===\nmsg\n")
    File.write!(Path.join(tmp_dir, "001.md"), "alpha\n")
    File.write!(Path.join(tmp_dir, "002.md"), "beta\n")

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
        llm: %{
          provider: "claude",
          adapter_opts: %{mode: "smart"},
          prompt_overrides: %{
            2 => %{provider: "codex", model: "gpt-5.3-codex"}
          }
        }
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.llm_sdk == :claude
    assert config.model == "haiku"
    assert config.prompt_overrides["02"].sdk == :codex
    assert config.prompt_overrides["02"].provider == :codex
    assert config.adapter_opts == %{mode: "smart"}

    prompt = %Prompt{num: "02", phase: 1, sp: 1, name: "Beta", file: "002.md", target_repos: nil}
    llm = Config.llm_for_prompt(config, prompt)

    assert llm.sdk == :codex
    assert llm.provider == :codex
    assert llm.model == "gpt-5.3-codex"
  end

  test "accepts legacy sdk keys for backward compatibility" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    prompts_path = Path.join(tmp_dir, "prompts.txt")
    commits_path = Path.join(tmp_dir, "commit-messages.txt")
    config_path = Path.join(tmp_dir, "runner_config.exs")

    File.write!(prompts_path, "01|1|1|Alpha|001.md\n")
    File.write!(commits_path, "=== COMMIT 01 ===\nmsg\n")
    File.write!(Path.join(tmp_dir, "001.md"), "alpha\n")

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
        llm: %{sdk: "claude_agent_sdk"}
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.llm_sdk == :claude
  end

  test "normalizes legacy permission_mode values" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "prompt_runner_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    prompts_path = Path.join(tmp_dir, "prompts.txt")
    commits_path = Path.join(tmp_dir, "commit-messages.txt")
    config_path = Path.join(tmp_dir, "runner_config.exs")

    File.write!(prompts_path, "01|1|1|Alpha|001.md\n02|1|1|Beta|002.md\n")
    File.write!(commits_path, "=== COMMIT 01 ===\nmsg\n=== COMMIT 02 ===\nmsg\n")
    File.write!(Path.join(tmp_dir, "001.md"), "alpha\n")
    File.write!(Path.join(tmp_dir, "002.md"), "beta\n")

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
        llm: %{
          sdk: "claude_agent_sdk",
          permission_mode: :bypass_permissions,
          prompt_overrides: %{
            "02" => %{sdk: "codex_sdk", permission_mode: "bypass_permissions"}
          }
        }
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.permission_mode == :full_auto

    prompt_01 = %Prompt{
      num: "01",
      phase: 1,
      sp: 1,
      name: "Alpha",
      file: "001.md",
      target_repos: nil
    }

    prompt_02 = %Prompt{
      num: "02",
      phase: 1,
      sp: 1,
      name: "Beta",
      file: "002.md",
      target_repos: nil
    }

    assert Config.llm_for_prompt(config, prompt_01).permission_mode == :full_auto
    assert Config.llm_for_prompt(config, prompt_02).permission_mode == :full_auto
  end
end
