# Configuration Reference

Prompt Runner now has two configuration styles:

- convention mode via API/CLI options
- explicit legacy config via `runner_config.exs`

## Convention Mode Options

These are the options used by `PromptRunner.plan/2`, `run/2`, `run_prompt/2`,
and `mix prompt_runner ...`.

| Option | Type | Meaning |
|--------|------|---------|
| `target` | string or repeated | Repo path or `name:path` target |
| `targets` | map or list | Named target repo map for API use |
| `provider` | atom/string | `:claude`, `:codex`, or `:amp` |
| `model` | string | Model name |
| `interface` | atom | `:api` or `:cli` |
| `state_dir` | string | Override the CLI runtime state directory |
| `no_state` | boolean | Disable persisted runtime state |
| `runtime_store` | atom/string | Override runtime store selection |
| `committer` | atom/string | Override committer selection |
| `log_mode` | atom/string | `:compact`, `:verbose`, or `:studio` |
| `log_meta` | atom/string | `:none` or `:full` |
| `events_mode` | atom/string | `:compact`, `:full`, or `:off` |
| `tool_output` | atom/string | `:summary`, `:preview`, or `:full` |
| `on_event` | function | Global observer callback |
| `on_prompt_started` | function | Lifecycle callback |
| `on_prompt_completed` | function | Lifecycle callback |
| `on_prompt_failed` | function | Lifecycle callback |
| `on_run_completed` | function | Lifecycle callback |

## Convention Metadata

Convention prompts support:

- front matter keys: `num`, `phase`, `sp`, `targets`, `commit`, `validation`
- heading fallbacks: `#`, `## Mission`, `## Validation Commands`, `## Repository Root`

See [Convention Mode](convention-mode.md) for examples.

## Legacy Config

`runner_config.exs` is still loaded through `PromptRunner.Config.load/1`.

```elixir
%{
  project_dir: "/path/to/repo",
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "haiku",
  llm: %{
    provider: "claude",
    prompt_overrides: %{
      "02" => %{provider: "codex", model: "gpt-5.3-codex"}
    }
  }
}
```

### Required Legacy Fields

| Field | Meaning |
|-------|---------|
| `project_dir` | Default working directory |
| `prompts_file` | Prompt manifest |
| `commit_messages_file` | Commit message source |
| `progress_file` | Progress log |
| `log_dir` | Session logs |
| `model` | Default model |

### Legacy `llm` Fields

| Field | Meaning |
|-------|---------|
| `provider` | Provider alias |
| `model` | Optional override of root model |
| `allowed_tools` | Tool restriction list |
| `permission_mode` | Provider permission policy |
| `adapter_opts` | Adapter-specific options |
| `claude_opts` | Claude-specific options |
| `codex_opts` | Codex-specific options |
| `codex_thread_opts` | Codex thread options |
| `cli_confirmation` | Codex CLI confirmation policy |
| `timeout` | Timeout override |
| `prompt_overrides` | Per-prompt LLM overrides |

### Important Layering Notes

These fields do not all mean the same thing or apply at the same layer.

- `allowed_tools`
  - Prompt Runner level tool allowlist passed through to the selected adapter.
- `permission_mode`
  - Prompt Runner's shared provider-facing permission knob.
  - This is normalized here and then interpreted by the provider adapter or
    downstream runtime.
- `codex_thread_opts`
  - Codex-only thread/session options passed through to `codex_sdk`.
  - This is where Codex-specific knobs such as `sandbox`,
    `ask_for_approval`, and `reasoning_effort` belong.
- `cli_confirmation`
  - Codex-only runner audit policy.
  - This checks whether the configured Codex model and reasoning settings were
    actually confirmed by the CLI.

Practical rule:

- use `permission_mode` when you want one runner-level approval/edit posture
  that can map onto multiple providers
- use `codex_thread_opts` when you need a real Codex thread option that does
  not exist as a shared provider knob

### Multi-Repo Legacy Fields

| Field | Meaning |
|-------|---------|
| `target_repos` | Named repo definitions |
| `repo_groups` | Named repo groups for `@group` expansion |

## Defaults By Interface

| Interface | Runtime Store | Committer |
|-----------|---------------|-----------|
| API | memory | noop |
| CLI | file | git |
| Legacy config | explicit files | git |

## Environment and Global Config

Convention mode also reads:

- `PROMPT_RUNNER_MODEL`
- `PROMPT_RUNNER_PROVIDER`
- `~/.config/prompt_runner/config.exs` if it exists

CLI/API options win over those defaults.
## Recovery-Related Provider Options

Prompt Runner now forwards recovery-relevant provider options through the current ASM stack instead
of keeping a legacy adapter-specific option surface.

- Claude supports `system_prompt` and `append_system_prompt`
- Codex supports `system_prompt` via the underlying thread base-instructions surface
- Gemini supports `system_prompt`
- Amp does not advertise `system_prompt`, and Prompt Runner now rejects that unsupported input
  instead of silently dropping it

On recoverable runtime failures, Prompt Runner will attempt an exact provider-session resume with
`Continue` before it gives up on the run.
