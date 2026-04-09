# Multi-Repo Dummy Example Configuration
#
# SDK dependencies required by this example:
#   - codex_sdk (default provider)
#   - claude_agent_sdk (prompt 02 override)
#   - amp_sdk (prompt 03 override)
#   - gemini_cli_sdk (prompt 04 override)
#
# When running standalone via run_prompts.exs, these are pulled automatically.
# When using prompt_runner_sdk as a Hex dependency, add them to your mix.exs.
# See guides/providers.md for details.

base_dir = __DIR__
repos_dir = Path.join(base_dir, "repos")
alpha_dir = Path.join(repos_dir, "alpha")
beta_dir = Path.join(repos_dir, "beta")

%{
  project_dir: repos_dir,
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "sonnet",
  allowed_tools: ["Read", "Write", "Bash"],
  permission_mode: :bypass,
  log_mode: :compact,
  log_meta: :none,
  events_mode: :compact,
  phase_names: %{1 => "Multi Repo Example"},
  target_repos: [
    %{name: "alpha", path: alpha_dir, default: true},
    %{name: "beta", path: beta_dir}
  ],
  llm: %{
    sdk: "codex_sdk",
    model: "gpt-5.3-codex",
    prompt_overrides: %{
      "02" => %{
        sdk: "claude_agent_sdk",
        model: "sonnet",
        permission_mode: :bypass,
        allowed_tools: ["Bash"]
      },
      "03" => %{
        sdk: "amp_sdk",
        model: "amp-1",
        permission_mode: :bypass,
        allowed_tools: ["Bash"]
      },
      "04" => %{
        sdk: "gemini_cli_sdk",
        model: "gemini-2.5-flash",
        permission_mode: :bypass,
        allowed_tools: ["run_shell_command"]
      }
    }
  }
}
