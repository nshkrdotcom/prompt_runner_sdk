defmodule PromptRunner.GitTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Config
  alias PromptRunner.Git

  @moduletag :git_tests

  describe "commit_single_repo/2 bug" do
    setup do
      # Create unique temp directories for each test
      test_id = System.unique_integer([:positive])
      base_dir = Path.join(System.tmp_dir!(), "prs_git_test_#{test_id}")

      default_project = Path.join(base_dir, "default_project")
      target_repo = Path.join(base_dir, "target_repo")

      # Create both directories
      File.mkdir_p!(default_project)
      File.mkdir_p!(target_repo)

      # Initialize git repos
      init_git_repo(default_project)
      init_git_repo(target_repo)

      # Create config and commit messages files
      config_dir = Path.join(base_dir, "config")
      File.mkdir_p!(config_dir)

      commit_messages_path = Path.join(config_dir, "commit-messages.txt")

      File.write!(commit_messages_path, """
      === COMMIT 01:target_repo ===
      test: single repo commit

      === COMMIT 01 ===
      test: fallback commit message
      """)

      prompts_path = Path.join(config_dir, "prompts.txt")
      File.write!(prompts_path, "01|1|1|Test|001.md|target_repo\n")

      on_exit(fn -> File.rm_rf!(base_dir) end)

      %{
        base_dir: base_dir,
        default_project: default_project,
        target_repo: target_repo,
        config_dir: config_dir,
        commit_messages_path: commit_messages_path,
        prompts_path: prompts_path
      }
    end

    defp init_git_repo(path) do
      System.cmd("git", ["init", "-q"], cd: path)
      System.cmd("git", ["config", "user.name", "Test"], cd: path)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: path)
      File.write!(Path.join(path, "README.md"), "# Test\n")
      System.cmd("git", ["add", "README.md"], cd: path)
      System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)
    end

    @tag :fix_verification
    test "FIXED: commit_single_repo with explicit repo path commits to correct directory", ctx do
      # This test verifies the fix:
      # When repo_name and repo_path are passed, commit_single_repo commits to
      # the correct target repo, not config.project_dir

      config = %Config{
        config_dir: ctx.config_dir,
        project_dir: ctx.default_project,
        target_repos: [
          %{name: "target_repo", path: ctx.target_repo, default: true}
        ],
        prompts_file: ctx.prompts_path,
        commit_messages_file: ctx.commit_messages_path,
        progress_file: Path.join(ctx.config_dir, ".progress"),
        log_dir: Path.join(ctx.config_dir, "logs"),
        llm_sdk: :claude,
        model: "sonnet",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{},
        log_mode: :compact,
        log_meta: :none,
        events_mode: :compact,
        phase_names: %{},
        repo_groups: %{}
      }

      # Create a file in the TARGET repo (where the LLM would write)
      test_file = Path.join(ctx.target_repo, "NEW_FILE.md")
      File.write!(test_file, "# New file created by LLM\n")

      # Call commit_single_repo with explicit repo info (as runner.ex now does)
      result = Git.commit_single_repo(config, "01", "target_repo", ctx.target_repo)

      # Should return {:ok, sha} because we're now checking the correct directory
      assert match?({:ok, _sha}, result),
             "commit_single_repo should succeed when given explicit repo path, got: #{inspect(result)}"

      # Verify the commit went to target_repo
      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: ctx.target_repo)
      assert String.contains?(log, "single repo commit")
    end

    @tag :fix_verification
    test "FIXED: target_repo has no uncommitted changes after commit_single_repo with explicit path",
         ctx do
      # This test verifies the fix works end-to-end:
      # After commit_single_repo with explicit repo info, target_repo has no uncommitted changes

      config = %Config{
        config_dir: ctx.config_dir,
        project_dir: ctx.default_project,
        target_repos: [
          %{name: "target_repo", path: ctx.target_repo, default: true}
        ],
        prompts_file: ctx.prompts_path,
        commit_messages_file: ctx.commit_messages_path,
        progress_file: Path.join(ctx.config_dir, ".progress"),
        log_dir: Path.join(ctx.config_dir, "logs"),
        llm_sdk: :claude,
        model: "sonnet",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{},
        log_mode: :compact,
        log_meta: :none,
        events_mode: :compact,
        phase_names: %{},
        repo_groups: %{}
      }

      # Create a file in the target repo
      test_file = Path.join(ctx.target_repo, "SHOULD_BE_COMMITTED.md")
      File.write!(test_file, "# This should be committed\n")

      # Run commit_single_repo with explicit repo info (as runner.ex now does)
      result = Git.commit_single_repo(config, "01", "target_repo", ctx.target_repo)
      assert match?({:ok, _}, result)

      # Check git status in target_repo - should have no uncommitted changes
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.target_repo)

      assert String.trim(status) == "",
             "target_repo should have no uncommitted changes after commit, but found: #{status}"
    end

    @tag :backward_compatibility
    test "commit_single_repo without explicit path falls back to config.project_dir", ctx do
      # This test verifies backward compatibility:
      # When called without repo_name/repo_path, it still uses config.project_dir

      config = %Config{
        config_dir: ctx.config_dir,
        project_dir: ctx.default_project,
        target_repos: [
          %{name: "target_repo", path: ctx.target_repo, default: true}
        ],
        prompts_file: ctx.prompts_path,
        commit_messages_file: ctx.commit_messages_path,
        progress_file: Path.join(ctx.config_dir, ".progress"),
        log_dir: Path.join(ctx.config_dir, "logs"),
        llm_sdk: :claude,
        model: "sonnet",
        prompt_overrides: %{},
        allowed_tools: nil,
        permission_mode: nil,
        claude_opts: %{},
        codex_opts: %{},
        codex_thread_opts: %{},
        log_mode: :compact,
        log_meta: :none,
        events_mode: :compact,
        phase_names: %{},
        repo_groups: %{}
      }

      # Create a file in the DEFAULT project (config.project_dir)
      test_file = Path.join(ctx.default_project, "DEFAULT_FILE.md")
      File.write!(test_file, "# File in default project\n")

      # Call commit_single_repo WITHOUT explicit repo info (backward compatible call)
      result = Git.commit_single_repo(config, "01")

      # Should commit to config.project_dir (backward compatibility)
      assert match?({:ok, _sha}, result),
             "commit_single_repo should still work with 2-arg call, got: #{inspect(result)}"

      # Verify the commit went to default_project
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.default_project)
      assert String.trim(status) == ""
    end
  end

  describe "commit_single_repo/2 with explicit repo path (proposed fix)" do
    setup do
      test_id = System.unique_integer([:positive])
      base_dir = Path.join(System.tmp_dir!(), "prs_git_fix_test_#{test_id}")

      target_repo = Path.join(base_dir, "target_repo")
      File.mkdir_p!(target_repo)

      # Initialize git repo
      System.cmd("git", ["init", "-q"], cd: target_repo)
      System.cmd("git", ["config", "user.name", "Test"], cd: target_repo)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: target_repo)
      File.write!(Path.join(target_repo, "README.md"), "# Test\n")
      System.cmd("git", ["add", "README.md"], cd: target_repo)
      System.cmd("git", ["commit", "-q", "-m", "initial"], cd: target_repo)

      config_dir = Path.join(base_dir, "config")
      File.mkdir_p!(config_dir)

      commit_messages_path = Path.join(config_dir, "commit-messages.txt")

      File.write!(commit_messages_path, """
      === COMMIT 01:my_repo ===
      test: explicit repo path commit
      """)

      on_exit(fn -> File.rm_rf!(base_dir) end)

      %{
        base_dir: base_dir,
        target_repo: target_repo,
        config_dir: config_dir,
        commit_messages_path: commit_messages_path
      }
    end

    @tag :proposed_fix
    test "commit_repo/4 works correctly with explicit path", ctx do
      # This test verifies that the underlying commit_repo function works
      # when given the correct path directly

      # Create a file in target_repo
      test_file = Path.join(ctx.target_repo, "EXPLICIT_PATH.md")
      File.write!(test_file, "# Committed via explicit path\n")

      # Call commit_repo directly with the correct path
      result =
        Git.commit_repo(ctx.target_repo, "test: explicit repo path commit", "01", "my_repo")

      assert match?({:ok, _sha}, result), "commit_repo should succeed with explicit path"

      # Verify the commit exists
      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: ctx.target_repo)
      assert String.contains?(log, "explicit repo path commit")

      # Verify no uncommitted changes remain
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.target_repo)
      assert String.trim(status) == ""
    end
  end
end
