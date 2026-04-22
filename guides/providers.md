# Provider Guide

Prompt Runner delegates provider execution to `agent_session_manager`.
This guide targets `prompt_runner_sdk ~> 0.7.0`.

Supported providers:

| Provider | Key | CLI command |
|----------|-----|-------------|
| Claude | `:claude` | `claude` |
| Codex | `:codex` | `codex` |
| Gemini | `:gemini` | `gemini` |
| Amp | `:amp` | `amp` |
| Simulated | `:simulated` | built in |

Prompt Runner always starts ASM sessions with `lane: :core`, so host
applications do not need the provider SDK packages just to run Prompt Runner.

## Default Profile Posture

`mix prompt_runner init` creates `codex-default` with:

- `provider: codex`
- `model: gpt-5.4`
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

These packet or prompt keys work across providers:

- `provider`
- `model`
- `allowed_tools`
- `permission_mode`
- `timeout`
- `system_prompt`
- `append_system_prompt`
- `max_turns`

Normalized shared permission modes:

- `default`
- `auto`
- `bypass`
- `plan`

Codex currently rejects shared `permission_mode: auto`, so use `default`,
`bypass`, or `plan` for Codex packets.

## Provider-Specific Option Maps

Prompt Runner also accepts provider-specific maps where the underlying ASM
surface supports them:

- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `gemini_opts`
- `amp_opts`

Codex-only thread settings belong in `codex_thread_opts`, for example:

```yaml
codex_thread_opts:
  reasoning_effort: "xhigh"
  additional_directories:
    - "./repos/beta"
```

Do not put raw unsupported CLI flags such as `sandbox` or `ask_for_approval`
under `codex_thread_opts`.

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
model: "gpt-5.4"
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
