# Simple Example Configuration
#
# Prompt Runner runs this example through ASM core lane. No provider SDK
# packages are required in the host project.

base_dir = __DIR__
workspace_dir = Path.join(base_dir, "workspace")

%{
  project_dir: workspace_dir,
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "sonnet",
  allowed_tools: ["Bash"],
  permission_mode: :bypass,
  log_mode: :compact,
  log_meta: :none,
  events_mode: :compact,
  phase_names: %{1 => "Example"},
  llm: %{
    provider: "claude",
    model: "sonnet",
    prompt_overrides: %{
      "02" => %{provider: "codex", model: "gpt-5.3-codex"},
      "03" => %{provider: "amp", model: "amp-1", permission_mode: :bypass},
      "04" => %{
        provider: "gemini",
        model: "gemini-2.5-flash",
        permission_mode: :bypass,
        allowed_tools: ["run_shell_command"]
      }
    }
  }
}
