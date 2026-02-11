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
          timeout: 120_000,
          adapter_opts: %{mode: "smart"},
          prompt_overrides: %{
            2 => %{provider: "codex", model: "gpt-5.3-codex", timeout: 420_000}
          }
        }
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.llm_sdk == :claude
    assert config.model == "haiku"
    assert config.timeout == 120_000
    assert config.prompt_overrides["02"].sdk == :codex
    assert config.prompt_overrides["02"].provider == :codex
    assert config.adapter_opts == %{mode: "smart"}

    prompt = %Prompt{num: "02", phase: 1, sp: 1, name: "Beta", file: "002.md", target_repos: nil}
    llm = Config.llm_for_prompt(config, prompt)

    assert llm.sdk == :codex
    assert llm.provider == :codex
    assert llm.model == "gpt-5.3-codex"
    assert llm.timeout == 420_000
  end

  test "rejects invalid timeout values" do
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
        llm: %{provider: "claude", timeout: 0}
      }
      """
    )

    assert {:error, errors} = Config.load(config_path)
    assert {:timeout, {:invalid_timeout, 0}} in errors
  end

  test "accepts unbounded timeout sentinel values" do
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
        llm: %{provider: "claude", timeout: :unbounded, prompt_overrides: %{"01" => %{timeout: "infinity"}}}
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.timeout == :unbounded

    prompt = %Prompt{
      num: "01",
      phase: 1,
      sp: 1,
      name: "Alpha",
      file: "001.md",
      target_repos: nil
    }

    llm = Config.llm_for_prompt(config, prompt)
    assert llm.timeout == :infinity
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

  test "normalizes llm.cli_confirmation policy and supports prompt override" do
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
        model: "gpt-5.3-codex",
        llm: %{
          provider: "codex",
          cli_confirmation: "warn",
          codex_thread_opts: %{reasoning_effort: :xhigh},
          prompt_overrides: %{
            "02" => %{cli_confirmation: :require}
          }
        }
      }
      """
    )

    assert {:ok, config} = Config.load(config_path)
    assert config.cli_confirmation == :warn

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

    assert Config.llm_for_prompt(config, prompt_01).cli_confirmation == :warn
    assert Config.llm_for_prompt(config, prompt_02).cli_confirmation == :require
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

  describe "llm_for_prompt/2 repo-aware cwd" do
    test "uses the prompt target repo as cwd" do
      config = %Config{
        project_dir: "/workspace/prompts",
        target_repos: [
          %{name: "claude_agent_sdk", path: "/repos/claude_agent_sdk", default: true},
          %{name: "codex_sdk", path: "/repos/codex_sdk", default: false}
        ],
        repo_groups: %{},
        llm_sdk: :codex,
        model: "gpt-5.3-codex",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        adapter_opts: %{},
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{},
        timeout: nil
      }

      prompt = %Prompt{
        num: "02",
        phase: 1,
        sp: 5,
        name: "Codex Work",
        file: "prompts/02.md",
        target_repos: ["codex_sdk"]
      }

      llm = Config.llm_for_prompt(config, prompt)

      assert llm.cwd == "/repos/codex_sdk"
      assert llm.codex_thread_opts.additional_directories == []
    end

    test "uses default repo cwd when prompt target_repos are not specified" do
      config = %Config{
        project_dir: "/workspace/prompts",
        target_repos: [
          %{name: "claude_agent_sdk", path: "/repos/claude_agent_sdk", default: true},
          %{name: "codex_sdk", path: "/repos/codex_sdk", default: false}
        ],
        repo_groups: %{},
        llm_sdk: :codex,
        model: "gpt-5.3-codex",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        adapter_opts: %{},
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{},
        timeout: nil
      }

      prompt = %Prompt{
        num: "01",
        phase: 1,
        sp: 5,
        name: "Claude Work",
        file: "prompts/01.md",
        target_repos: nil
      }

      llm = Config.llm_for_prompt(config, prompt)
      assert llm.cwd == "/repos/claude_agent_sdk"
    end

    test "adds non-cwd target repos as Codex additional_directories" do
      config = %Config{
        project_dir: "/workspace/prompts",
        target_repos: [
          %{name: "claude_agent_sdk", path: "/repos/claude_agent_sdk", default: true},
          %{name: "codex_sdk", path: "/repos/codex_sdk", default: false}
        ],
        repo_groups: %{},
        llm_sdk: :codex,
        model: "gpt-5.3-codex",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        adapter_opts: %{},
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{additional_directories: ["/already/there"]},
        timeout: nil
      }

      prompt = %Prompt{
        num: "07",
        phase: 3,
        sp: 3,
        name: "Review",
        file: "prompts/07.md",
        target_repos: ["claude_agent_sdk", "codex_sdk"]
      }

      llm = Config.llm_for_prompt(config, prompt)

      assert llm.cwd == "/repos/claude_agent_sdk"

      assert llm.codex_thread_opts.additional_directories == [
               "/already/there",
               "/repos/codex_sdk"
             ]
    end
  end
end
