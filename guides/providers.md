# Provider Guide

Prompt Runner delegates provider execution to `agent_session_manager`.
This guide targets `prompt_runner_sdk ~> 0.5.0`.

Supported providers:

| Provider | Key | Optional dependency | Version for 0.5.0 |
|----------|-----|---------------------|-------------------|
| Claude | `:claude` | `claude_agent_sdk` | `~> 0.17.0` |
| Codex | `:codex` | `codex_sdk` | `~> 0.16.0` |
| Gemini | `:gemini` | `gemini_cli_sdk` | `~> 0.2.0` |
| Amp | `:amp` | `amp_sdk` | `~> 0.5.0` |

## Add Only What You Use

```elixir
def deps do
  [
    {:prompt_runner_sdk, "~> 0.5.0"},
    {:claude_agent_sdk, "~> 0.17.0"},
    {:codex_sdk, "~> 0.16.0"},
    {:gemini_cli_sdk, "~> 0.2.0"},
    {:amp_sdk, "~> 0.5.0"}
  ]
end
```

If a provider dependency is missing at runtime, Prompt Runner reports which
dependency to add.

Prompt Runner does not rely on `agent_session_manager` to pull the provider
SDKs transitively. Keeping them explicit in the host project makes dependency
resolution and runtime validation deterministic.

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
- `codex_thread_opts` is a Codex-only option map for thread/session settings
  that Prompt Runner still forwards through the current ASM Codex surface, such
  as `reasoning_effort`, `additional_directories`, `skip_git_repo_check`, and
  `output_schema`
- `cli_confirmation` is not a Codex runtime permission setting; it is a Prompt
  Runner audit policy for Codex CLI confirmation events

Normalized shared permission modes:

- `:default`
- `:auto`
- `:bypass`
- `:plan`

Provider-native CLI labels are downstream details. Keep Prompt Runner config on
the shared normalized modes above.

Codex exception:

- the current ASM/Codex contract intentionally rejects shared `permission_mode:
  :auto` for Codex
- use `:default`, `:bypass`, or `:plan` with Prompt Runner's shared
  `permission_mode`
- keep Codex-specific execution settings in `codex_thread_opts`

Example:

```elixir
llm: %{
  provider: "codex",
  permission_mode: :bypass,
  cli_confirmation: :require,
  codex_thread_opts: %{
    reasoning_effort: :xhigh,
    additional_directories: ["/repo-b"]
  }
}
```

In that configuration:

- `permission_mode` is the shared runner-level approval/edit posture
- `reasoning_effort` and `additional_directories` are Codex-only settings
- `cli_confirmation` controls whether Prompt Runner warns or fails when Codex
  CLI confirmation metadata does not match expectations

Do not put raw Codex CLI thread flags such as `sandbox` or `ask_for_approval`
under `codex_thread_opts`. The current ASM-owned Codex surface for Prompt
Runner does not accept those keys.

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

## Provider Recovery Semantics

The current provider posture is:

- Claude: provider-native session history and resume are available through the current ASM runtime
- Codex: exact thread resumption is preferred when a provider session id is known
- Gemini: typed session history and runtime-neutral resume are available
- Amp: thread-history resume is available, but unsupported prompt-control surfaces such as
  `system_prompt`, `append_system_prompt`, and `max_turns` are rejected

Prompt Runner uses those provider-native session surfaces only for recoverable failures. Fatal
data-loss events such as unrecoverable overflow still terminate the run honestly.
