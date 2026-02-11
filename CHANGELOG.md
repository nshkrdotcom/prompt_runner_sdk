# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-02-11

### Added

- **Studio rendering mode** (`log_mode: :studio`) — CLI-grade interactive output using AgentSessionManager's new `StudioRenderer`
  - Human-readable tool summaries instead of raw JSON token streams
  - Status symbols: `◐` (running), `✓` (success), `✗` (failure), `●` (info)
  - Three tool output verbosity levels via `tool_output:` config: `:summary` (default), `:preview`, `:full`
  - Automatic non-TTY fallback for piped/redirected output
- New `--tool-output` CLI flag for runtime verbosity override (`summary`, `preview`, `full`)
- New `tool_output` config key in runner configuration
- Redesigned prompt header with box-drawing characters and aligned layout in studio mode
- New guide: `guides/rendering.md` documenting all three rendering modes
- **Codex CLI confirmation and model auditing** — verify that the Codex CLI is actually using the model and reasoning effort you configured
  - New `cli_confirmation` config key (`:off`, `:warn`, `:require`) — controls response to confirmation mismatches
  - New `--cli-confirmation MODE` CLI flag for runtime override
  - New `--require-cli-confirmation` CLI flag (shortcut for `--cli-confirmation require`)
  - Machine-readable audit lines written to session logs (`LLM_AUDIT`, `LLM_AUDIT_CONFIRMED`, `LLM_AUDIT_RESULT`)
  - Mismatch and missing-confirmation warnings printed to console when `cli_confirmation: :warn` (default for Codex)
  - Hard failure when `cli_confirmation: :require` and CLI does not confirm reasoning effort
  - Per-prompt `cli_confirmation` override via `prompt_overrides`
- **Unbounded and infinite timeout support** — `timeout` now accepts `:unbounded`, `:infinity`, `"unbounded"`, `"infinity"`, and `"infinite"` in addition to positive integers
  - Sentinel values resolve to a 7-day emergency cap in the session layer
  - Works in both top-level config and per-prompt `prompt_overrides`
- **LLM SDK preflight checks** — Runner verifies that the required SDK module is loaded before starting a prompt (currently Codex only), with clear error messages including the missing package name
- **Stream error handling** — `Rendering.stream/2` failures (exceptions, throws) are now caught and returned as `{:error, {:stream_failed, message}}` instead of crashing the runner
- Codex `reasoning_effort` displayed in prompt plan output when configured via `codex_thread_opts`

### Changed

- Default `log_mode` remains `:compact` (studio is opt-in for this release)
- Default `cli_confirmation` is `:warn` for Codex prompts, effectively a no-op for other providers
- Modularized `Runner` internals — extracted helper functions for prompt header printing, permission mode display, adapter option display, and codex thread options
- Updated `guides/configuration.md` with new rendering, timeout, and CLI confirmation options
- Updated `guides/providers.md` with Codex reasoning effort and CLI confirmation details
- Updated `guides/getting-started.md` with studio mode and new CLI flags
- Updated README with rendering modes section and new CLI options

### Dependencies

- Requires `agent_session_manager ~> 0.8.0` (StudioRenderer module)
- `claude_agent_sdk` updated to `~> 0.12.0`
- `codex_sdk` updated to `~> 0.8.0`

## [0.3.0] - 2026-02-09

### Changed

- **Migrated rendering to `AgentSessionManager.Rendering`** — `Runner` now builds a renderer/sink pipeline from config instead of calling `StreamRenderer.stream/4`. Uses `CompactRenderer` or `VerboseRenderer` with `TTYSink`, `FileSink`, `JSONLSink`, and `CallbackSink`.
- **Migrated session lifecycle to `AgentSessionManager.StreamSession`** — `Session` now delegates stream creation, task management, and cleanup to `StreamSession.start/1` instead of hand-rolling ~200 lines of `Stream.resource`, receive loop, error event constructors, task shutdown, and child cleanup.
- **Canonical event format** — `Session` no longer normalizes ASM events. Canonical events (`:run_started`, `:message_streamed`, `:tool_call_started`, `:tool_call_completed`, `:run_completed`, etc.) pass through directly to the rendering pipeline.
- `Session.start_stream/2` signature and return type unchanged — existing callers work without modification.
- `start_adapter` replaced with `build_adapter_spec` returning `{Module, opts}` tuples instead of starting processes directly.
- `PromptRunner.Application` simplified — removed `PromptRunner.TaskSupervisor` and `PromptRunner.SessionSupervisor` (StreamSession manages its own lifecycle).
- Error tracking changed from `StreamRenderer` return value to `CallbackSink` with process dictionary (`Process.put/:prompt_runner_stream_result`).
- Session header now written directly to log file IO device via `IO.binwrite` instead of through `StreamRenderer.emit_line`.
- Tests updated to emit canonical ASM events instead of previously-normalized types.
- **Examples now use isolated workspace directories** — each example has `setup.sh` / `cleanup.sh` scripts and a standalone `run_prompts.exs` using `Mix.install`, so examples no longer operate within the SDK repository itself.
- Updated documentation (providers.md, getting-started.md, configuration.md, README) to reflect canonical event format, removed supervisors, new rendering pipeline, and example isolation.

### Removed

- **Deleted `PromptRunner.StreamRenderer`** (935 lines) — all rendering now handled by `AgentSessionManager.Rendering`.
- Removed `normalize_event/1` and all event normalization functions from `Session` (`:message_start`, `:text_delta`, `:tool_use_start`, `:tool_complete`, `:message_stop`, etc. mappings).
- Removed `build_stream_session`, `build_event_stream`, `next_stream_events`, `done_error_events`, `run_once`, `start_store`, `stop_task`, `await_task_exit`, `cleanup_children`, `terminate_child`, `start_supervised_child`, `ensure_runtime_started` from `Session` (all replaced by StreamSession).
- Removed `PromptRunner.TaskSupervisor` and `PromptRunner.SessionSupervisor` process tree entries.
- Removed `examples/simple/claude-output.txt` (examples now write to workspace directories).

### Added

- Standalone `run_prompts.exs` scripts for simple and multi-repo-dummy examples (use `Mix.install` for self-contained execution).
- `setup.sh` and `cleanup.sh` for the simple example to manage an isolated git workspace.
- `workspace/` added to `.gitignore` for example directories.

### Dependencies

- Requires `agent_session_manager ~> 0.7.0` (StreamSession and Rendering modules).

## [0.2.0] - 2026-02-08

### Added

- Added `PromptRunner.Application` OTP supervision tree with:
  - `PromptRunner.TaskSupervisor` for run execution tasks.
  - `PromptRunner.SessionSupervisor` for adapter/store process lifecycle.
- Added `PromptRunner.Session` as the AgentSessionManager bridge layer.
- Added support for provider alias `amp` (`amp_sdk`) in LLM normalization.
- Added `adapter_opts` config support at both root and `llm` scopes.
- **Normalized adapter options passthrough** — Session now forwards these config keys to all adapters:
  - `permission_mode` — `:default`, `:accept_edits`, `:plan`, `:full_auto`, or `:dangerously_skip_permissions`
  - `max_turns` — integer turn limit (Claude: unlimited by default, Codex: SDK default 10, Amp: no-op)
  - `system_prompt` — system-level instructions (Claude: `system_prompt`, Codex: `base_instructions`, Amp: stored only)
  - `sdk_opts` — keyword list of arbitrary provider-specific SDK options (normalized options take precedence)
- **Claude `cwd` passthrough** — Session passes `project_dir` as `cwd` to the Claude adapter, so the Claude CLI runs in the correct working directory.

### Changed

- Migrated runtime execution from direct SDK integration to `agent_session_manager`.
- Reworked `PromptRunner.LLMFacade` into a thin delegator to `PromptRunner.Session`.
- Updated config normalization to accept both `provider` and legacy `sdk` keys.
- Updated examples and CLI help text to use `provider` in config snippets.
- Updated README guidance from dual-SDK to multi-provider terminology.

### Removed

- Removed direct `PromptRunner.LLM.CodexNormalizer` integration and tests.
- Removed direct `claude_agent_sdk` and `codex_sdk` dependency declarations.

### Dependencies

- Added `agent_session_manager ~> 0.6.0` (now `~> 0.7.0` as of 0.3.0).

## [0.1.2] - 2026-01-26

### Added

- New `RepoTargets` module for expanding repo group references in target_repos.
  Groups are defined in config as `repo_groups: %{"pipeline" => ["command", "flowstone"]}`
  and referenced in prompts.txt as `@pipeline`.
- Support for nested group references (e.g., `@portfolio` containing `@pipeline`).
- Cycle detection for repo group definitions with clear error messages.
- Validator now checks repo-specific commit messages for default repo when prompt
  has no explicit target_repos.
- Test suites for `RepoTargets` and `Validator` modules.

### Changed

- `Runner` now expands repo group references before resolving target repositories.
- `Validator` expands repo groups when checking commit messages and repo references.
- Improved error handling when target repos cannot be resolved.

## [0.1.1] - 2026-01-26

### Fixed

- Fixed single-repo commit path bug where `commit_single_repo` always committed to `config.project_dir` instead of the resolved target repository path. Now correctly passes repo name and path from `runner.ex` to `git.ex`.

### Changed

- Added `:inets` to extra_applications for OTP HTTP client support.
- `commit_single_repo/2` now accepts optional `repo_name` and `repo_path` parameters for explicit targeting.

### Dependencies

- Updated `ex_doc` from 0.39.3 to 0.40.0.
- Updated `finch` from 0.20.0 to 0.21.0.

## [0.1.0] - 2026-01-18

- Initial release.
- Prompt runner CLI with streaming output.
- Claude Agent SDK and Codex SDK support via a unified facade.
- Multi-repo prompt execution with per-repo commit messages.
- Example prompt sets for single-repo and multi-repo workflows.

[Unreleased]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/releases/tag/v0.1.0
