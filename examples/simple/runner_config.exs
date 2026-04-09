# Simple Example Configuration
#
# SDK dependencies required by this example:
#   - claude_agent_sdk (prompt 01 uses Claude)
#   - codex_sdk (prompt 02 uses Codex)
#   - amp_sdk (prompt 03 uses Amp)
#   - gemini_cli_sdk (prompt 04 uses Gemini)
#
# When running standalone via run_prompts.exs, these are pulled automatically.
# When using prompt_runner_sdk as a Hex dependency, add them to your mix.exs.
# See guides/providers.md for details.

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
    sdk: "claude_agent_sdk",
    model: "sonnet",
    prompt_overrides: %{
      "02" => %{sdk: "codex_sdk", model: "gpt-5.3-codex"},
      "03" => %{sdk: "amp_sdk", model: "amp-1", permission_mode: :bypass},
      "04" => %{
        sdk: "gemini_cli_sdk",
        model: "gemini-2.5-flash",
        permission_mode: :bypass,
        allowed_tools: ["run_shell_command"]
      }
    }
  }
}
