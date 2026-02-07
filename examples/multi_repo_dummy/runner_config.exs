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
  model: "haiku",
  allowed_tools: ["Read", "Write", "Bash"],
  permission_mode: :accept_edits,
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
    codex_thread_opts: %{
      sandbox: :workspace_write,
      ask_for_approval: :never
    },
    prompt_overrides: %{
      "02" => %{
        sdk: "claude_agent_sdk",
        model: "haiku",
        permission_mode: :bypass_permissions,
        allowed_tools: ["Bash"]
      }
    }
  }
}
