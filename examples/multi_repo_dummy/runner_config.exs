# Multi-Repo Dummy Example Configuration
#
# Prompt Runner runs this example through ASM core lane. No provider SDK
# packages are required in the host project.

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
    provider: "codex",
    model: "gpt-5.3-codex",
    prompt_overrides: %{
      "02" => %{
        provider: "claude",
        model: "sonnet",
        permission_mode: :bypass,
        allowed_tools: ["Bash"]
      },
      "03" => %{
        provider: "amp",
        model: "amp-1",
        permission_mode: :bypass,
        allowed_tools: ["Bash"]
      },
      "04" => %{
        provider: "gemini",
        model: "gemini-2.5-flash",
        permission_mode: :bypass,
        allowed_tools: ["run_shell_command"]
      }
    }
  }
}
