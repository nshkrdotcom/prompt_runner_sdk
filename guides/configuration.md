# Configuration Reference

Configuration lives in a `runner_config.exs` file — an Elixir script that evaluates to a map. It is loaded by `PromptRunner.Config.load/1`.

## Full Config

```elixir
%{
  # === Required ===
  project_dir: "/path/to/project",
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "haiku",

  # === Optional: Multi-repo ===
  target_repos: [
    %{name: "app", path: "/path/to/app", default: true},
    %{name: "lib", path: "/path/to/lib"}
  ],
  repo_groups: %{
    "all" => ["app", "lib"]
  },

  # === Optional: LLM ===
  llm: %{
    provider: "claude",
    model: "haiku",
    permission_mode: :accept_edits,
    allowed_tools: ["Read", "Write", "Bash"],
    max_turns: nil,
    system_prompt: nil,
    sdk_opts: [],
    adapter_opts: %{},
    claude_opts: %{},
    codex_opts: %{},
    codex_thread_opts: %{},
    prompt_overrides: %{
      "03" => %{provider: "codex", model: "gpt-5.3-codex"}
    }
  },

  # === Optional: Display ===
  log_mode: :compact,
  log_meta: :none,
  events_mode: :compact,
  phase_names: %{1 => "Setup", 2 => "Implementation"}
}
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `project_dir` | string | Absolute path to project root. Used as the LLM working directory (`cwd`). |
| `prompts_file` | string | Path to prompt index file (relative to `project_dir`). |
| `commit_messages_file` | string | Path to commit messages file (relative to `project_dir`). |
| `progress_file` | string | Path to progress tracking file (relative to `project_dir`). |
| `log_dir` | string | Directory for session logs (relative to `project_dir`). |
| `model` | string | Default model name (e.g., `"haiku"`, `"sonnet"`, `"gpt-5.3-codex"`). |

All relative paths are resolved against the directory containing the config file.

## LLM Section

The `llm` map controls provider selection, tool permissions, and per-prompt overrides.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `provider` | string | `"claude"` | Provider name: `"claude"`, `"codex"`, or `"amp"`. |
| `model` | string | root `model` | Overrides the top-level `model`. |
| `allowed_tools` | list | `nil` | Tool names the LLM may use (e.g., `["Read", "Write", "Bash"]`). |
| `permission_mode` | atom | `nil` | `:default`, `:accept_edits`, `:plan`, `:full_auto`, or `:dangerously_skip_permissions`. |
| `max_turns` | integer | `nil` | Maximum agentic turns. Claude: nil=unlimited. Codex: nil=SDK default (10). Amp: ignored. |
| `system_prompt` | string | `nil` | System-level instructions. Claude: `system_prompt`. Codex: `base_instructions`. Amp: stored only. |
| `sdk_opts` | keyword | `[]` | Arbitrary provider-specific SDK options. Normalized options take precedence. |
| `adapter_opts` | map | `%{}` | Options passed to the AgentSessionManager adapter. |
| `claude_opts` | map | `%{}` | Claude-specific adapter options (merged before `adapter_opts`). |
| `codex_opts` | map | `%{}` | Codex-specific options (merged before `adapter_opts`). |
| `codex_thread_opts` | map | `%{}` | Codex thread options (merged before `adapter_opts`). |
| `prompt_overrides` | map | `%{}` | Per-prompt overrides keyed by prompt number. |

### Config Precedence

For each prompt, `PromptRunner.Config.llm_for_prompt/2` deep-merges in this order (lowest to highest):

1. Root-level keys (`model`, `allowed_tools`, `permission_mode`, etc.)
2. `llm` section values
3. `prompt_overrides` entry for the specific prompt number

The resulting map is passed to `PromptRunner.Session.start_stream/2`.

### Provider Aliases

The `provider` key accepts multiple aliases. The legacy `sdk` key is also accepted for backward compatibility.

| Input | Resolves To |
|-------|-------------|
| `"claude"`, `"claude_agent"`, `"claude_agent_sdk"` | `:claude` |
| `"codex"`, `"codex_sdk"` | `:codex` |
| `"amp"`, `"amp_sdk"` | `:amp` |

```elixir
# All equivalent:
llm: %{provider: "claude"}
llm: %{sdk: "claude_agent_sdk"}
llm: %{provider: "claude_agent"}
```

### prompt_overrides

Override any LLM setting for a specific prompt. Keys can be integers (auto-padded to `"02"` format) or strings:

```elixir
llm: %{
  provider: "claude",
  model: "haiku",
  prompt_overrides: %{
    "03" => %{provider: "codex", model: "gpt-5.3-codex"},
    5 => %{model: "sonnet", adapter_opts: %{max_tokens: 16384}}
  }
}
```

Overrides are deep-merged, so you only need to specify the fields that change.

### adapter_opts

Provider-agnostic options passed directly to the AgentSessionManager adapter. This map is merged *after* provider-specific options (`claude_opts`, `codex_opts`, etc.), so it takes precedence:

```elixir
llm: %{
  provider: "claude",
  adapter_opts: %{max_tokens: 8192}
}
```

`adapter_opts` can also appear at the root level of the config. The `llm`-scoped value takes precedence if both are present.

## Multi-Repo Fields

| Field | Type | Description |
|-------|------|-------------|
| `target_repos` | list | List of repo maps. Each has `:name` (string), `:path` (string), and optional `:default` (boolean). |
| `repo_groups` | map | Named groups of repos. Keys are group names, values are lists of repo names or `@group` references. |

See the [Multi-Repository Workflows](multi-repo.md) guide for full details.

## Display Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `log_mode` | atom | `:compact` | `:compact` (abbreviated tokens) or `:verbose` (one event per line). |
| `log_meta` | atom | `:none` | `:none` or `:full` (include metadata in log tokens). |
| `events_mode` | atom | `:compact` | `:compact`, `:full`, or `:off`. Controls JSONL event file detail level. |
| `phase_names` | map | `%{}` | Map of phase number (integer) to display name (string). |

## File Formats

### prompts.txt

Each line defines one prompt. Lines starting with `#` or blank lines are skipped.

```
NUM|PHASE|SP|NAME|FILE[|TARGET_REPOS]
```

| Field | Type | Description |
|-------|------|-------------|
| NUM | string | Prompt identifier (`01`, `02`, ...). |
| PHASE | integer | Phase grouping. Used with `--phase` flag. |
| SP | integer | Story points (tracking only). |
| NAME | string | Display name. |
| FILE | string | Prompt markdown file path (relative to `project_dir`). |
| TARGET_REPOS | string | Optional. Comma-separated repo names or `@group` references. |

### commit-messages.txt

Markers delimit commit messages. Text between markers is the full commit message (can be multi-line).

Single repo:
```
=== COMMIT 01 ===
feat: setup database schema
```

Multi-repo (repo-qualified):
```
=== COMMIT 01:frontend ===
feat(frontend): initial setup

=== COMMIT 01:backend ===
feat(backend): initial setup
```

The marker regex is: `=== COMMIT (\d+)(?::(\w+))? ===`

For multi-repo prompts, the SDK looks for `NN:repo_name` first, then falls back to `NN`.

### progress file

Append-only log of prompt execution results. Format:

```
NUM:STATUS:TIMESTAMP[:COMMIT_INFO]
```

| Field | Values |
|-------|--------|
| STATUS | `completed` or `failed` |
| TIMESTAMP | ISO8601 datetime |
| COMMIT_INFO | SHA (`abc1234`), `no_changes`, `no_commit`, or repo map (`repo1=abc,repo2=def`) |

The SDK reads the *last* entry per prompt number when determining status.

## Logging

Each prompt execution produces two log files in `log_dir`:

1. **Text log** (`NN-name.log`) - Plain text with ANSI codes stripped
2. **Events log** (`NN-name.events.jsonl`) - One JSON object per line

The events file detail level is controlled by `events_mode`:
- `:off` - No events file
- `:compact` - Abbreviated field names and short type codes
- `:full` - All event fields preserved

## Validation

`PromptRunner.Validator.validate_all/1` (invoked by `--validate`) checks:

1. Every prompt has a matching commit message (or repo-specific variants)
2. Every prompt markdown file exists
3. Every `TARGET_REPOS` reference resolves to a configured repo (including `@group` expansion)

Errors are collected and reported together with pass/fail indicators.
