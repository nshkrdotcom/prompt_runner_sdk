# Changelog

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

- Added `agent_session_manager ~> 0.6.0`.

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
