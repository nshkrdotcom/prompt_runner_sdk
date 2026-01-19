%{
  project_dir: "repos",
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "sonnet",
  allowed_tools: ["Read", "Write"],
  permission_mode: :accept_edits,
  log_mode: :compact,
  log_meta: :none,
  events_mode: :compact,
  phase_names: %{1 => "Multi Repo Example"},
  target_repos: [
    %{name: "alpha", path: "repos/alpha", default: true},
    %{name: "beta", path: "repos/beta"}
  ],
  llm: %{
    sdk: "claude_agent_sdk",
    model: "sonnet"
  }
}
