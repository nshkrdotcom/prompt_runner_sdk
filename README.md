<p align="center">
  <img src="assets/prompt_runner_sdk.svg" alt="Prompt Runner SDK" width="200" height="200">
</p>

<h1 align="center">Prompt Runner SDK</h1>

<p align="center">
  <strong>Convention-driven prompt orchestration for Elixir, Mix, and production applications</strong>
</p>

<p align="center">
  <a href="https://hex.pm/packages/prompt_runner_sdk"><img src="https://img.shields.io/hexpm/v/prompt_runner_sdk.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/prompt_runner_sdk"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Documentation"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

Prompt Runner SDK executes ordered prompt workflows against local repositories.
This README targets `prompt_runner_sdk ~> 0.6.1`.

It supports two equally valid styles:

- Convention-driven execution from a directory of numbered `.prompt.md` files.
- Explicit legacy execution from `runner_config.exs`, `prompts.txt`, and `commit-messages.txt`.

The core engine is library-first. The CLI, Mix task, standalone script, and
future release binaries all sit on top of the same runtime.

## Highlights

- `PromptRunner.run/2`, `plan/2`, `validate/2`, and `run_prompt/2` for embedded use.
- `mix prompt_runner ...` for local workflows.
- Convention mode with optional front matter and heading-based metadata.
- Runtime store defaults that are safe by context:
  API calls default to memory/noop commit.
  CLI calls default to `.prompt_runner/` state plus git commits.
- Legacy config compatibility without migration pressure.
- Claude, Codex, Gemini, and Amp support through `agent_session_manager`.
- Studio, compact, and verbose rendering modes.
- Observer callbacks and an optional PubSub bridge.

## Installation

```elixir
def deps do
  [
    {:prompt_runner_sdk, "~> 0.6.1"}
  ]
end
```

Prompt Runner is now an explicit `agent_session_manager` core-lane client.
Host projects do not need `codex_sdk`, `claude_agent_sdk`, `gemini_cli_sdk`,
or `amp_sdk` just to run Prompt Runner. Provider CLI discovery and execution
flow through ASM plus `cli_subprocess_core`.

For Codex, `cli_confirmation` auditing now accepts either hidden confirmation
metadata or the actual launched command args as the runtime proof source.

## Quick Start

### 1. Create a prompt directory

`prompts/01_auth.prompt.md`

```markdown
# Reconcile auth ownership

## Mission

Align the auth architecture across code and docs.

## Validation Commands

- `mix test`
```

### 2. Run it from Mix

```bash
mix prompt_runner run ./prompts --target /path/to/repo --provider claude --model haiku
```

### 3. List or inspect the plan

```bash
mix prompt_runner list ./prompts --target /path/to/repo
mix prompt_runner plan ./prompts --target /path/to/repo
```

CLI runs store progress and logs in `./prompts/.prompt_runner/` by default.

## Programmatic API

```elixir
{:ok, plan} =
  PromptRunner.plan("./prompts",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )

{:ok, run} =
  PromptRunner.run("./prompts",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku",
    on_event: fn event -> IO.inspect(event.type) end
  )
```

Single prompt execution works without any files:

```elixir
{:ok, run} =
  PromptRunner.run_prompt(
    "Create hello.txt with a greeting.",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

API calls default to:

- `MemoryStore` for progress/state.
- `NoopCommitter` for post-run behavior.

That keeps embedded production use free of surprise filesystem writes and git
commits unless you explicitly opt into them.

## CLI Surfaces

### Mix task

```bash
mix prompt_runner list ./prompts --target /repo
mix prompt_runner run ./prompts --target /repo
mix prompt_runner validate ./prompts --target /repo
mix prompt_runner scaffold ./prompts --output ./generated --target /repo
```

### Standalone script

The root `run_prompts.exs` file remains available for legacy config-driven runs:

```bash
mix run run_prompts.exs --config runner_config.exs --run 01
```

### Escript

```bash
mix escript.build
./prompt_runner list ./prompts --target /repo
```

## Legacy Config Mode

Existing v0.4 projects continue to work:

```bash
mix run run_prompts.exs --config runner_config.exs --list
mix run run_prompts.exs --config runner_config.exs --run 01
mix run run_prompts.exs --config runner_config.exs --run --all
```

Legacy config is still the right fit when you want:

- hand-authored `prompts.txt`
- hand-authored `commit-messages.txt`
- per-prompt provider overrides via `prompt_overrides`
- fixed checked-in runner files

## Documentation Map

- [Getting Started](guides/getting-started.md)
- [Convention Mode](guides/convention-mode.md)
- [CLI Guide](guides/cli.md)
- [API Guide](guides/api.md)
- [Configuration Reference](guides/configuration.md)
- [Legacy Config Mode](guides/legacy-config.md)
- [Provider Guide](guides/providers.md)
- [Rendering Modes](guides/rendering.md)
- [Multi-Repository Workflows](guides/multi-repo.md)
- [Architecture](guides/architecture.md)
- [Migration Notes](guides/migration.md)
- [Examples](examples/README.md)

## Examples

- `examples/simple/` shows the explicit legacy single-repo workflow.
- `examples/multi_repo_dummy/` shows explicit multi-repo commits.

## Development

```bash
mix test
mix format
mix credo --strict
mix docs
```

For sibling-repo development against a local checkout of
`agent_session_manager`, opt in explicitly:

```bash
PROMPT_RUNNER_USE_LOCAL_DEPS=1 mix deps.get
PROMPT_RUNNER_USE_LOCAL_DEPS=1 mix test
```

Hex remains the default dependency source, and `mix hex.build` /
`mix hex.publish` ignore that local-deps opt-in so package metadata stays
Hex-clean.

## License

MIT
## Resume-First Recovery

`prompt_runner_sdk` now treats provider-native session continuation as the first recovery path for
recoverable transport/protocol failures.

- prompt runs cache provider-native recovery metadata as the stream progresses
- recoverable protocol/transport failures trigger an exact-session resume attempt with `Continue`
  before any prompt replay is considered
- the runner preserves the original/root provider error and attaches any failed recovery attempt as
  secondary context instead of overwriting it with generic transport noise
- prompt-numbering `--continue` remains distinct from provider session continuation

This repo now depends on the current `agent_session_manager` session runtime rather than the older
adapter seam so those recovery handles can flow end to end.
