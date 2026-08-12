# Provider Guide

Prompt Runner delegates provider execution to `agent_session_manager`.
This guide targets `prompt_runner_sdk ~> 0.12.1`.

Supported providers:

| Provider | Key | CLI command |
|----------|-----|-------------|
| Claude | `:claude` | `claude` |
| Codex | `:codex` | `codex` |
| Amp | `:amp` | `amp` |
| Cursor | `:cursor` | `agent` |
| Antigravity | `:antigravity` | `agy` |
| Simulated | `:simulated` | built in |

Prompt Runner always starts ASM sessions with `lane: :core`, so host
applications do not need the provider SDK packages just to run Prompt Runner.

## Default Profile Posture

`mix prompt_runner init` creates `codex-default` with:

- `provider: codex`
- `model: gpt-5.6-luna`
- `reasoning_effort: xhigh`
- `permission_mode: bypass`
- `cli_confirmation: require`

Packets can use that profile directly or override any of those values locally.

`mix prompt_runner init` also creates `simulated-default` for zero-dependency
recovery demos:

- `provider: simulated`
- `model: simulated-demo`
- `permission_mode: bypass`
- `cli_confirmation: off`
- `recovery.resume_attempts: 2`
- `recovery.retry.base_delay_ms: 0`
- `recovery.retry.max_delay_ms: 0`
- `recovery.repair.enabled: true`

## Shared Provider Knobs

These packet or prompt keys are shared across providers:

- `provider`
- `model`
- `allowed_tools`
- `permission_mode`
- `timeout`
- `system_prompt`
- `append_system_prompt`
- `max_turns`

Provider support for `system_prompt`, `append_system_prompt`, and `max_turns`
is validated before launch; unsupported controls fail configuration instead
of being silently ignored.

Normalized shared permission modes:

- `default`
- `auto`
- `bypass`
- `plan`

Not every provider accepts every mode. Prompt Runner delegates the decision to
`ASM.Permission.normalize/2`, so an unsupported pairing fails at config load
with `{:invalid_permission_mode, provider, mode}` rather than at launch. On
`agent_session_manager ~> 0.15.0`, Cursor and Antigravity reject `auto`, and
Antigravity additionally rejects `plan`.

## Normalized Common Options

ASM 0.11/0.12 promoted several formerly provider-local settings to normalized
options that every provider schema accepts structurally and that are gated at
runtime by the provider's common-feature manifest. Prompt Runner accepts them
in any provider option map:

- `allow_unknown_model` — let a model newer than the shared registry through
  to the CLI instead of failing validation
- `completion_only` — a no-write, no-approval posture; supported by Claude and
  Codex, and rejected with a typed capability error by Amp, Antigravity, and
  Cursor
- `output_schema` — structured output, gated by the `structured_output`
  capability (Claude sends an inline JSON schema, Codex a schema file path)
- `transport_headless_timeout_ms` — the finite bound used to reap an orphaned
  transport, independent of stream idle timeout

## Provider-Specific Option Maps

Prompt Runner also accepts provider-specific maps where the underlying ASM
surface supports them:

- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `amp_opts`
- `cursor_opts`
- `antigravity_opts`

Cursor and Antigravity accept only the option keys exposed by their current
ASM core profiles. Unsupported keys fail during config validation instead of
being forwarded as arbitrary CLI flags.

Gemini CLI support is retired. Use Antigravity for Google's coding-agent CLI.
The `gemini_ex` package is a distinct model API SDK, not an alias for this
provider surface.

Codex-only thread settings belong in `codex_thread_opts`, for example:

```yaml
codex_thread_opts:
  reasoning_effort: "xhigh"
  additional_directories:
    - "./repos/beta"
```

Do not put raw unsupported CLI flags such as `sandbox` or `ask_for_approval`
under `codex_thread_opts`.

Claude accepts `reasoning_effort` in `agent_session_manager ~> 0.15.0`; it
resolves through the shared model registry the same way Codex's does.
`include_thinking` remains the separate control for thinking output:

```yaml
claude_opts:
  reasoning_effort: "high"
  include_thinking: true
```

Codex additionally exposes its app-server surface through `codex_opts`:

- `app_server`
- `host_tools`
- `dynamic_tools`
- `reviewed_approval`

## Simulated Provider

The built-in simulated provider is for deterministic retry, repair, and resume
demos. It does not use `agent_session_manager` or any external provider
process.

It is package-local runtime support, not a service-mode simulation selector.
Stack-level service-mode proofs should configure ASM and `cli_subprocess_core`
runtime profiles so Prompt Runner still exercises the normal ASM core lane.

## Codex CLI Confirmation

Codex packets can require runtime confirmation that the configured model and
reasoning effort actually launched:

```yaml
provider: "codex"
model: "gpt-5.6-luna"
reasoning_effort: "xhigh"
cli_confirmation: "require"
```

Modes:

- `off`
- `warn`
- `require`

Prompt Runner accepts either hidden confirmation metadata or the actual
launched command args as the proof source.

## Working Directory Behavior

The provider `cwd` is the first targeted repo for the prompt. Additional repo
paths are projected into Codex additional directories when they are part of the
prompt target set.
