%{
  project_dir: "../..",
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "sonnet",
  allowed_tools: ["Read"],
  permission_mode: :accept_edits,
  log_mode: :compact,
  log_meta: :none,
  events_mode: :compact,
  phase_names: %{1 => "Example"},
  llm: %{
    sdk: "claude_agent_sdk",
    model: "sonnet",
    prompt_overrides: %{
      "02" => %{sdk: "codex_sdk", model: "gpt-5.1-codex"}
    }
  }
}
