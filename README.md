<p align="center">
  <img src="assets/prompt_runner_sdk.svg" alt="Prompt Runner SDK" width="200" height="200">
</p>

<h1 align="center">Prompt Runner SDK</h1>

<p align="center">
  <strong>Run ordered prompt sequences with streaming output, automatic git commits, and multi-provider LLM support</strong>
</p>

<p align="center">
  <a href="https://hex.pm/packages/prompt_runner_sdk"><img src="https://img.shields.io/hexpm/v/prompt_runner_sdk.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/prompt_runner_sdk"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Documentation"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

---

## What It Does

Prompt Runner SDK executes a sequence of LLM prompts against your codebase. Each prompt is sent to an LLM provider, the response is streamed in real time, and the resulting changes are committed to git automatically.

- **Streaming output** - See responses as they're generated (compact or verbose mode)
- **Automatic git commits** - Each prompt gets its own commit with a predefined message
- **Multi-provider support** - Claude, Codex, and Amp through [AgentSessionManager](https://hex.pm/packages/agent_session_manager)
- **Progress tracking** - Resume interrupted runs with `--continue`
- **Multi-repository** - Orchestrate prompts across multiple repos with per-repo commits
- **Per-prompt overrides** - Switch providers, models, or tool permissions for individual prompts
- **Validation** - Check config, prompt files, commit messages, and repo references before running

## Installation

```elixir
def deps do
  [{:prompt_runner_sdk, "~> 0.2.0"}]
end
```

The SDK starts an OTP supervision tree automatically (`PromptRunner.Application`) with supervisors for task execution and adapter lifecycle.

## Quick Example

```elixir
# runner_config.exs
%{
  project_dir: File.cwd!(),
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "haiku",
  llm: %{provider: "claude"}
}
```

```
# prompts.txt — format: NUM|PHASE|SP|NAME|FILE
01|1|1|Setup database|001-setup.md
02|1|3|Add API layer|002-api.md
```

```
# commit-messages.txt
=== COMMIT 01 ===
feat: setup database schema

=== COMMIT 02 ===
feat: add API layer
```

```bash
mix run run_prompts.exs -c runner_config.exs --run 01
```

## CLI

```bash
# Info
mix run run_prompts.exs -c config.exs --list              # List prompts + status
mix run run_prompts.exs -c config.exs --validate           # Validate config, files, repos
mix run run_prompts.exs -c config.exs --dry-run 01         # Preview without executing

# Run
mix run run_prompts.exs -c config.exs --run 01             # Run one prompt
mix run run_prompts.exs -c config.exs --run --all          # Run all prompts
mix run run_prompts.exs -c config.exs --run --continue     # Resume from last completed
mix run run_prompts.exs -c config.exs --run --phase 2      # Run all prompts in phase 2

# Options
--no-commit                  # Skip git commits
--project-dir DIR            # Override project_dir
--repo-override name:path    # Override a repo path (repeatable)
--log-mode compact|verbose   # Output mode (default: compact)
--log-meta none|full         # Metadata in log output (default: none)
--events-mode compact|full|off  # JSONL event logging (default: compact)
```

## Multi-Provider Support

Switch between Claude, Codex, and Amp. Override per-prompt:

```elixir
%{
  llm: %{
    provider: "claude",
    model: "haiku",
    allowed_tools: ["Read", "Write", "Bash"],
    permission_mode: :accept_edits,
    prompt_overrides: %{
      "03" => %{provider: "codex", model: "gpt-5.3-codex"},
      "05" => %{provider: "amp"}
    }
  }
}
```

Normalized options that work across all providers:

```elixir
llm: %{
  provider: "claude",
  permission_mode: :dangerously_skip_permissions,
  max_turns: 10,
  system_prompt: "Be concise.",
  sdk_opts: [verbose: true],       # arbitrary provider-specific SDK options
  adapter_opts: %{max_tokens: 16384}  # passed to adapter directly
}
```

## Multi-Repository Support

Target prompts at specific repos. Define repo groups with `@` references:

```elixir
%{
  target_repos: [
    %{name: "frontend", path: "/path/to/frontend", default: true},
    %{name: "backend", path: "/path/to/backend"}
  ],
  repo_groups: %{
    "all" => ["frontend", "backend"]
  }
}
```

```
# prompts.txt — 6th field is TARGET_REPOS
01|1|5|Setup both|001-setup.md|@all
02|1|8|Frontend only|002-frontend.md|frontend
```

```
# commit-messages.txt — repo-qualified markers
=== COMMIT 01:frontend ===
feat(frontend): initial setup

=== COMMIT 01:backend ===
feat(backend): initial setup
```

## Architecture

```
run_prompts.exs
       |
  PromptRunner.CLI           -- parse args, route commands
       |
  PromptRunner.Config        -- load, normalize, validate config
       |
  PromptRunner.Runner        -- orchestrate prompt sequence
       |
  PromptRunner.LLMFacade     -- thin delegator (LLM behaviour)
       |
  PromptRunner.Session       -- AgentSessionManager bridge
       |                        starts store + adapter per prompt,
       |                        normalizes events to common format
  AgentSessionManager
   +-- ClaudeAdapter
   +-- CodexAdapter
   +-- AmpAdapter
```

Supporting modules: `Prompts` (parse prompts.txt), `CommitMessages` (parse commit messages), `Progress` (track completion), `Git` (commit changes), `Validator` (pre-run checks), `RepoTargets` (expand `@group` references). Rendering is handled by `AgentSessionManager.Rendering`.

## Examples

| Example | Description |
|---------|-------------|
| `examples/simple/` | Single repo, provider override (Claude default, Codex for prompt 02) |
| `examples/multi_repo_dummy/` | Two repos (alpha, beta), per-repo commits, provider switching |

```bash
# Try the multi-repo example
bash examples/multi_repo_dummy/setup.sh
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --list
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 01
```

## Guides

- **[Getting Started](guides/getting-started.md)** - Installation, prerequisites, first run
- **[Configuration Reference](guides/configuration.md)** - All config keys and file formats
- **[Multi-Provider Setup](guides/providers.md)** - Claude, Codex, Amp configuration
- **[Multi-Repository Workflows](guides/multi-repo.md)** - Cross-repo orchestration and repo groups

## Development

```bash
mix test           # Run tests
mix credo --strict # Lint
mix dialyzer       # Type check
mix docs           # Generate docs
```

## License

MIT - see [LICENSE](LICENSE)
