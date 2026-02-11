# Getting Started

## Installation

Add `prompt_runner_sdk` to your `mix.exs` dependencies:

```elixir
def deps do
  [{:prompt_runner_sdk, "~> 0.4.0"}]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

The SDK starts an OTP application via `PromptRunner.Application`. Session lifecycle (stores, adapters, tasks) is managed by `AgentSessionManager.StreamSession` — no manual setup is needed.

## Prerequisites

You need at least one LLM provider's API key set in your environment:

| Provider | Environment Variable |
|----------|---------------------|
| Claude | `ANTHROPIC_API_KEY` |
| Codex | `OPENAI_API_KEY` |
| Amp | `AMP_API_KEY` |

## Create Your First Config

You need four files. All paths in the config are relative to `project_dir` unless absolute.

### 1. runner_config.exs

```elixir
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

### 2. prompts.txt

Each line defines a prompt. Format: `NUM|PHASE|SP|NAME|FILE`

```
01|1|1|Hello world|001-hello.md
```

| Field | Description |
|-------|-------------|
| NUM | Prompt number (01, 02, ...). Used to identify the prompt everywhere. |
| PHASE | Phase grouping (integer). Used with `--phase` to run groups of prompts. |
| SP | Story points (integer). For tracking purposes only. |
| NAME | Display name shown in `--list` and log output. |
| FILE | Markdown file containing the prompt text (relative to `project_dir`). |

### 3. commit-messages.txt

Each prompt needs a commit message block:

```
=== COMMIT 01 ===
feat: hello world prompt
```

The text between markers becomes the git commit message (can be multi-line).

### 4. 001-hello.md

The actual prompt content sent to the LLM:

```markdown
Create a file called hello.txt with the text "Hello from Prompt Runner!".
```

## Run It

```bash
# Validate everything first
mix run run_prompts.exs -c runner_config.exs --validate

# Preview without executing
mix run run_prompts.exs -c runner_config.exs --dry-run 01

# Execute the prompt
mix run run_prompts.exs -c runner_config.exs --run 01
```

The SDK will:
1. Load and validate your config (`PromptRunner.Config.load/1`)
2. Read your prompt from `001-hello.md`
3. Start an adapter for the configured provider via AgentSessionManager
4. Stream events through the rendering pipeline (you see output in real time)
5. Log output to `logs/` (plain text + JSONL events)
6. Commit changes with your commit message via `PromptRunner.Git`
7. Record completion in `.progress`

## CLI Reference

### Commands

```bash
--help, -h                   # Show help text with example config
--list                       # List all prompts with completion status
--validate, -v               # Validate config, files, and repo references
--dry-run TARGET             # Preview execution plan without running
--plan-only, -p              # Generate execution plan
--run TARGET                 # Execute prompt(s)
```

### Run Targets

```bash
--run 01                     # Run specific prompt by number
--run --all                  # Run all prompts sequentially
--run --continue             # Resume from the prompt after the last completed
--run --phase 2              # Run all prompts in phase 2
```

### Run Options

```bash
--no-commit                  # Execute prompt but skip the git commit step
--project-dir DIR            # Override project_dir from config
--repo-override name:path    # Override a repo's path (repeatable)
--log-mode compact|verbose|studio  # Streaming output format (default: compact)
--log-meta none|full         # Reserved for future use (currently ignored)
--events-mode compact|full|off  # JSONL event logging detail (default: compact)
--tool-output summary|preview|full  # Studio tool verbosity (default: summary)
--cli-confirmation off|warn|require  # Codex CLI model confirmation policy
--require-cli-confirmation   # Shortcut for --cli-confirmation require
```

### Progress and Resumption

The progress file (`.progress` by default) tracks prompt completion:

```
01:completed:2026-02-08T17:30:45.123456Z:abc1234567
02:failed:2026-02-08T17:35:22.654321Z
```

- `--continue` finds the last completed prompt and starts from the next one
- `--list` shows completion status for each prompt
- Failed prompts can be re-run by number

### Output Modes

**Compact mode** (default) uses abbreviated tokens with ANSI colors:

```
r+ haiku >> Hello world t+Write t-Write tr:ok r-:end
5 events, 1 tools
```

Token legend: `r+` run started, `r-` run completed, `t+`/`t-` tool start/end, `>>` text stream, `tk:` token usage, `!` error.

**Verbose mode** shows one event per line:

```
[run_started] model=haiku session_id=ses_123
Hello world
[tool_call_started] name=Write id=tu_001 input={"path":"hello.txt"}
[tool_call_completed] name=Write output=ok
[run_completed] stop_reason=end_turn
--- 5 events, 1 tools ---
```

**Studio mode** (`--log-mode studio`) produces clean, human-readable output with status symbols and tool summaries:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Prompt 01: Hello world
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ● haiku session started
  ✓ Write hello.txt (1 line)
  ● Session complete (end_turn) — 123/45 tokens, 1 tools
  ✓ Prompt 01 completed
```

Control tool output verbosity with `--tool-output summary|preview|full`. See the [Rendering Modes](rendering.md) guide for details.

## Next Steps

- [Configuration Reference](configuration.md) - All config keys, file formats, and defaults
- [Rendering Modes](rendering.md) - Compact, verbose, and studio output modes
- [Multi-Provider Setup](providers.md) - Configure Claude, Codex, or Amp with per-prompt overrides
- [Multi-Repository Workflows](multi-repo.md) - Target prompts at multiple repos with repo groups
