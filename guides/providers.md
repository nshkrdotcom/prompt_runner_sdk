# Provider Guide

Prompt Runner delegates provider execution to `agent_session_manager`.

Supported providers:

| Provider | Key | Optional dependency |
|----------|-----|---------------------|
| Claude | `:claude` | `claude_agent_sdk` |
| Codex | `:codex` | `codex_sdk` |
| Amp | `:amp` | `amp_sdk` |

## Add Only What You Use

```elixir
def deps do
  [
    {:prompt_runner_sdk, "~> 0.5.0"},
    {:claude_agent_sdk, "~> 0.14.0"}
  ]
end
```

If a provider dependency is missing at runtime, Prompt Runner reports which
dependency to add.

## Selecting A Provider

Convention/API mode:

```elixir
PromptRunner.run("./prompts", target: "/repo", provider: :claude, model: "haiku")
```

Legacy config:

```elixir
%{
  model: "haiku",
  llm: %{provider: "claude"}
}
```

## Codex CLI Confirmation

Codex runs can verify that the configured model and reasoning effort were
actually confirmed by the CLI.

Legacy config example:

```elixir
llm: %{
  provider: "codex",
  model: "gpt-5.3-codex",
  cli_confirmation: :warn,
  codex_thread_opts: %{reasoning_effort: :xhigh}
}
```

Modes:

- `:off`
- `:warn`
- `:require`

## Shared Versus Codex-Specific Knobs

Prompt Runner exposes two different kinds of execution settings:

- shared runner/provider settings
- Codex-only thread settings

Shared settings:

- `allowed_tools`
- `permission_mode`

Codex-only settings:

- `codex_thread_opts`
- `cli_confirmation`

That distinction matters:

- `permission_mode` is the shared knob that Prompt Runner passes into the
  selected provider adapter
- `codex_thread_opts` is a direct pass-through map for real `codex_sdk` thread
  options such as `sandbox` and `ask_for_approval`
- `cli_confirmation` is not a Codex runtime permission setting; it is a Prompt
  Runner audit policy for Codex CLI confirmation events

Example:

```elixir
llm: %{
  provider: "codex",
  permission_mode: :accept_edits,
  cli_confirmation: :require,
  codex_thread_opts: %{
    sandbox: :workspace_write,
    ask_for_approval: :never,
    reasoning_effort: :xhigh
  }
}
```

In that configuration:

- `permission_mode` is the shared runner-level approval/edit posture
- `sandbox` and `ask_for_approval` are Codex thread options only
- `cli_confirmation` controls whether Prompt Runner warns or fails when Codex
  CLI confirmation metadata does not match expectations

## Legacy Per-Prompt Overrides

Per-prompt provider switching currently lives in legacy config via
`prompt_overrides`:

```elixir
llm: %{
  provider: "claude",
  model: "haiku",
  prompt_overrides: %{
    "02" => %{provider: "codex", model: "gpt-5.3-codex"}
  }
}
```

## Working Directory Behavior

Prompt Runner computes provider `cwd` from the prompt target repo when targets
are configured. Otherwise it falls back to the configured project directory.
