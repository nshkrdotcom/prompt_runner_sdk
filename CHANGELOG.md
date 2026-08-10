# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-08-10

Shaped by a thirty-session unattended program built on 0.8.1. Every addition
here is something that program had to build for itself in shell, and every fix
is something it hit in the field.

### Added

- `mix prompt_runner packet lint [DIR]`, a static authoring-hazard gate and the
  sibling of `packet doctor`. Doctor reports authoring *gaps*; lint reports
  authoring *hazards* — constructs that load cleanly, run, and produce a wrong
  answer without ever raising. Errors: a prompt id that does not match its
  filename's numeric prefix (ordering comes from the filename, so a mismatch
  silently reorders the run), a filename with no numeric prefix, duplicate
  prompt ids, an unknown repo in `targets:` or in a verify entry's `repo:`,
  legacy `@group` syntax in `targets:` (repo groups are never expanded for
  packets), and an unrecognized `verify:` clause. Warnings: a `verify.commands`
  entry not wrapped in `timeout`, a prompt with no `verify` contract, a
  contract with no `commands:` entry, `changed_paths_only` in a packet that
  runs with `--no-commit`, and the four inert front-matter keys.
  `--strict` promotes warnings to errors, `--json` emits a machine-readable
  report, and `--no-commit` enables the vacuity check. The known-clause list is
  read from `PromptRunner.Verifier.contract_keys/0` so lint and the verifier
  cannot drift.
- The `doc:` verify clause, an artifact-quality gate. `files_exist` is
  satisfied by a three-line stub, so a prompt whose deliverable is a written
  document had no way to assert the document was written. `doc:` asserts a
  non-blank line floor (`min_lines`), verbatim `requires_sections`, and the
  absence of `forbids_markers` (`TODO`/`TBD`/`FIXME`/`XXX` by default; an
  explicit empty list opts out, a custom list replaces the default).
- The `repos_clean:` verify clause, which asserts that sessions committed their
  own work. Under `--no-commit` the runner's committer never runs and
  `changed_paths_only` passes vacuously, because `git status --porcelain` is
  empty precisely because the session committed. `pushed: true` additionally
  requires an upstream and compares `HEAD` to it — a missing upstream is a
  failure, since the clause was asked to assert publication and cannot.
  `pushed: false` (the default) treats an absent upstream as fine. The upstream
  comparison fetches under a bounded timeout (`fetch_timeout_ms`, default 90s);
  a fetch that fails or times out is reported in `details:` and the comparison
  falls back to cached remote-tracking refs. Nothing mutates a working tree,
  an index, or a local branch.
- `mix prompt_runner watch [DIR]`, supervision for a long unattended run. One
  compact line per interval:
  `WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27`.
  `--interval SECONDS` (default 900), `--once`, and `--json`.
  `PromptRunner.Watch.sample/2` is public for host applications with their own
  monitoring.
- A run pid file. Any run with a file-backed state directory writes
  `.prompt_runner/run.pid` for its duration and removes it on exit, including
  on failure, so liveness can be checked by signalling a pid. `watch` uses it
  rather than a process-name match: such a pattern matches any command line
  containing it, including the supervisor's own shell, and reports a live run
  forever.
- `--dry-run` on `run`. The runner has honoured `opts[:dry_run]` since the
  packet rewrite, but no CLI switch ever set it, so
  `prompt_runner run <packet> --dry-run` dropped the unknown flag and started a
  real provider session.
- `PromptRunner.Verifier.contract_keys/0`, and read-only repository inspection
  in `PromptRunner.Git` (`worktree?/1`, `status_lines/1`, `commit_count/1`,
  `upstream_ref/1`, `fetch/3`) shared by the verifier and `watch`.
- Two guides: [Packet Linting](guides/linting.md) and
  [Supervising A Long Run](guides/supervision.md).

### Fixed

- A prompt that could not satisfy its verify contract repaired forever.
  `RecoveryPolicy.final_action/5` returns `{:verification_failed, ...}` when
  repair is *not* available — disabled, out of attempts, or the attempt was
  itself a repair — and the runner routed that outcome through the same
  function as `{:repair, ...}`, which returns `{:repair, ...}`. The outcome
  handler then started another repair attempt, which ran in `:repair` mode,
  took the same branch, and started another. An unattended run re-invoked the
  provider without bound while the attempt list in `state.json` grew on every
  pass. `{:verification_failed, ...}` is now terminal, and the failure names
  the unmet items instead of inspecting the whole verifier report.
- Call options were silently discarded by packet metadata. `Plan.merged_opts/2`
  normalized option keys once, *after* merging every layer, so
  `%{"provider" => "claude"}` from a packet manifest and
  `%{provider: "simulated"}` from the call site both survived the deep merge as
  distinct keys, and normalization-after-merge let whichever it visited last
  win — by Erlang term order, the string one. Every CLI and API override was
  affected whenever the packet set the same key, and the failure pointed in the
  worst possible direction: a run intended for the simulated provider started
  the packet's live provider, at the packet's model, permission mode, and
  system prompt. Each layer is now normalized before it is merged.
- The ASM run deadline is derived from `timeout`. `ASM.Run.State` defaults
  `:run_deadline_ms` to 600_000 — a total wall-clock budget for the whole run,
  armed independently of the stream and transport timeouts — and Prompt Runner
  never set it. A packet that deliberately left `timeout` unset got seven days
  on the stream and transport bounds and ten minutes on the run, and every
  prompt doing more than a few minutes of work died with a
  `provider_runtime_claim` naming a deadline nothing had configured, after the
  model had already done the work and often after it had committed it. All four
  bounds now derive from `resolve_effective_timeout_ms/1`: an explicit
  `timeout` bounds the run, and an absent one means the seven-day emergency
  bound.
- `prompt_runner plan` reported the packet's provider regardless of overrides.
  `CLI.run_plan/1` parsed no flags and passed none to `PromptRunner.plan/2`, so
  the natural way to check an override before spending a session answered about
  a different plan than `run` would build. `plan` and `run` now share one switch
  list.

### Changed

- The built-in templates and `prompt new` no longer scaffold `references`,
  `required_reading`, `context_files`, or `depends_on`. None of them is read at
  runtime — they are parsed, stored on `PromptRunner.Prompt`, and never sent to
  the provider or used for ordering — so the first prompt anyone scaffolded
  taught them to record required reading in a field the model never sees. The
  `## Required Reading` body section stays, since the body is what reaches the
  model, and the `verify:` skeleton now offers `commands:` in place of
  `changed_paths_only:`. Prompts that still carry the keys keep working; lint
  reports them.
- Full documentation refresh for 0.9.0 across `README.md` and every guide,
  including the run-deadline behaviour, the difference between
  `changed_paths_only` and `repos_clean`, and why the terminal event counters
  are not evidence that a session did work.
- Release preparation now asserts that every documentation extra registered in
  `mix.exs` exists on disk and is grouped, and that every guide on disk is
  registered.

## [0.8.1] - 2026-08-03

### Changed

- Default live-provider models are now `gpt-5.6-luna` for Codex and `haiku`
  (Haiku 4.5) for Claude, across every default and every path that reaches a
  live provider:
  - the `codex-default` profile created by `mix prompt_runner init`
    (`gpt-5.4` -> `gpt-5.6-luna`, `reasoning_effort: xhigh` unchanged)
  - the legacy-interface fallback model (`claude-sonnet-4-6` -> `haiku`)
  - `examples/single_repo_packet` and `examples/multi_repo_packet`
    (`gpt-5.4-mini` -> `gpt-5.6-luna`)
  - `examples/claude_packet` (`sonnet` -> `haiku`)
  - the CLI help text and every guide/README sample
  The simulated packets are unaffected; they never contact a provider.
  Note that `haiku` is the shared model registry's id for Haiku 4.5 —
  `haiku-4.5` is not a registered id or alias and is rejected as an unknown
  model.

### Fixed

- Generated artifacts no longer carry a stale hardcoded version. The
  `run_prompts.exs` scaffold emitted `{:prompt_runner_sdk, "~> 0.7.0"}`, and
  both the CLI help banner and newly created packet manifests announced
  `Prompt Runner 0.7.0`, on a 0.8.0 install. Scaffolding a project from 0.8.0
  therefore produced a dependency entry one minor version behind.

### Changed

- `PromptRunner.version/0` is now the single source of truth for every version
  string Prompt Runner emits. It is baked in at compile time from `mix.exs`,
  and the CLI banner, generated packet manifests, and the scaffolded install
  entry all interpolate it.
- Added a release-preparation regression test that fails when any file under
  `lib/` hardcodes a release version, so this class of drift cannot ship again.

## [0.8.0] - 2026-08-03

### Added

- A live Claude provider example, `examples/claude_packet/`. It runs the same
  two prompts as `examples/single_repo_packet/` (Codex), so the pair is the
  shortest demonstration that a packet is provider-portable. Both were
  verified against their real CLIs for this release.
- The normalized common option surface introduced by
  `agent_session_manager` 0.11/0.12, accepted in every provider option map and
  gated at runtime by the provider's common-feature manifest:
  - `allow_unknown_model`
  - `completion_only`
  - `output_schema`
  - `transport_headless_timeout_ms`
- `reasoning_effort` for Claude, which resolves through the shared model
  registry the same way Codex's does. `include_thinking` remains the separate
  control for thinking output.
- The Codex app-server option surface in `codex_opts`: `app_server`,
  `host_tools`, `dynamic_tools`, and `reviewed_approval`.
- `mix deps.sources`, plus a `publish_preflight` regression test that fails
  when a committed Hex constraint cannot admit the sibling checkout it was
  developed against.

### Changed

- Moved dependency resolution onto the shared
  `build_support/dependency_sources.exs` helper (v7) vendored by the rest of
  this stack, replacing the bespoke `local_dev_or_hex_dep` selection in
  `mix.exs`. Sibling checkouts still win automatically, and a gitignored
  `.dependency_sources.local.exs` can now force Hex resolution — which is what
  makes `mix deps.get` fetch the packages that `mix hex.publish` requires.
- Raised the runtime floor to `agent_session_manager ~> 0.12.1` and
  `cli_subprocess_core ~> 0.4.1`. `cli_subprocess_core` is now a declared
  dependency rather than a local-only override, matching the fact that
  `PromptRunner.Session` consumes `CliSubprocessCore.Payload` directly.
- Refreshed the remaining dependencies: `ex_doc ~> 0.40.3`,
  `yaml_elixir ~> 2.12`, `mox ~> 1.2`, and `credo ~> 1.7.19`. The Credo floor
  is deliberate: 1.7.16 and earlier crash tokenizing Elixir 1.20 sigils.
- `output_schema` is no longer a Codex-local option. It is a normalized option
  gated by the `structured_output` capability, so Claude can request it too.
- Permission-mode validation is documented as capability-derived rather than
  hardcoded per provider, since the supported set moves with ASM.

### Fixed

- `mix hex.publish` could not run from a workspace checkout. `mix.lock` still
  pinned the stale `agent_session_manager 0.10.0` entry — which requires
  `cursor_cli_sdk`, a dependency ASM 0.12 dropped — and nothing in the old
  dependency selection could fetch the Hex packages that packaging needs. The
  lock is regenerated from a real Hex resolution and both modes now coexist.
- Removed an unreachable verifier-override branch from the final-action
  decision in `PromptRunner.RecoveryPolicy`. An earlier clause already handles
  a passing report on the provider-error path, so the branch could only ever
  raise `KeyError` or evaluate to false.
- Removed a dead `preflight_llm_provider/1` fallback clause; `llm_for_prompt/2`
  always populates `:sdk`.
- Dropped two redundant `||` fallbacks in the Codex CLI confirmation audit;
  `confirmation_source/1` already guarantees a default.
- The project again compiles cleanly under `--warnings-as-errors` on Elixir
  1.20, and `mix dialyzer` reports zero errors with no ignore file.

## [0.7.0] - 2026-07-13

### Changed

- Breaking change: redesigned Prompt Runner around packet directories,
  `prompt_runner_packet.md`, and prompt-local YAML front matter instead of the
  older duplicated control-file workflow.
- Added home-scoped profiles under `~/.config/prompt_runner/` and aligned the
  CLI around packet/profile authoring commands.
- Added first-class packet APIs:
  - `PromptRunner.Packet`
  - `PromptRunner.Packets`
  - `PromptRunner.Profile`
  - `PromptRunner.Runtime`
  - `PromptRunner.Verifier`
- Made completion verifier-owned. Prompt runs now record deterministic verifier
  reports in packet-local runtime state and use those reports to drive retry
  and repair decisions.
- Rebuilt the shipped examples as packet-native examples:
  - `examples/single_repo_packet`
  - `examples/multi_repo_packet`
- Rewrote the README, guides, and HexDocs menu around the packet/profile model.
- Standardized the release README badges and Hex/HexDocs package metadata.
- Aligned the public provider surface with `agent_session_manager ~> 0.10.0`:
  Claude, Codex, Amp, Cursor, and Antigravity. Gemini CLI support is retired;
  Antigravity is the Google coding-agent provider, while `gemini_ex` remains a
  distinct model API SDK.
- Added validated `cursor_opts` and `antigravity_opts` packet and prompt
  sections, plus common-runtime coverage for all five ASM providers.
- Raised the Elixir requirement to `~> 1.19` to match the ASM dependency floor.

### Fixed

- Packet, profile, and prompt-local execution options now normalize correctly
  at plan-build time, so packet-defined `provider`, `model`,
  `reasoning_effort`, and `codex_thread_opts` actually reach runtime
  execution.
- `mix prompt_runner run ...` now sets the correct command flag before
  delegating to the runner.
- `changed_paths_only` verification now inherits the prompt's default repo
  scope when entries omit an explicit `repo`.
- Packet runtime state now serializes common result tuples into readable JSON
  maps instead of opaque tuple placeholders.
- Hex packaging now uses an explicit shipped-example allowlist, excluding
  generated repos, workspaces, logs, runtime state, and nested Git data.

## [0.6.1] - 2026-04-09

### Changed

- Bumped the published `agent_session_manager` dependency to `~> 0.9.2`.
- Updated the standalone example runners to install
  `agent_session_manager ~> 0.9.2`.
- Refreshed README and guide version references for `prompt_runner_sdk ~> 0.6.1`.

## [0.6.0] - 2026-04-09

### Changed

- Removed direct provider SDK package requirements from `prompt_runner_sdk`.
  Host projects now install only `prompt_runner_sdk`, while provider CLI
  execution flows through `agent_session_manager` core lane plus
  `cli_subprocess_core`.
- Prompt Runner now starts ASM sessions with `lane: :core` explicitly instead
  of inheriting ASM's default `:auto` lane selection.
- Replaced provider-SDK runtime preflight with provider/core-lane preflight
  based on ASM provider metadata and common CLI discovery facts.
- Updated README, guides, scaffolding, and shipped examples to use provider
  names as the standard config surface and to stop installing provider SDK
  packages.

### Fixed

- Standalone scaffold output and shipped example `run_prompts.exs` files no
  longer declare unnecessary provider SDK dependencies.
- Prompt Runner now behaves consistently whether provider SDK packages happen
  to be installed locally or not, because the runner always stays on ASM core
  lane.

## [0.5.1] - 2026-04-09

### Changed

- Bumped the published Codex dependency guidance and package spec to
  `codex_sdk ~> 0.16.1`.
- Refreshed README, getting-started, provider docs, scaffolded dependency
  output, and example `Mix.install` snippets for the `0.5.1` / `0.16.1`
  release pair.

### Fixed

- Codex CLI confirmation auditing now falls back to the actual launched
  `run_started` command args when hidden confirmation metadata does not include
  model or reasoning details, so `cli_confirmation: :require` no longer fails
  falsely on otherwise-correct Codex runs.
- Hidden Codex confirmation events now merge event metadata with raw
  `thread.started` metadata before Prompt Runner evaluates the confirmation
  payload.

## [0.5.0] - 2026-04-08

### Changed

- Aligned the published dependency matrix with the current Hex releases:
  - `agent_session_manager ~> 0.9.1`
  - `claude_agent_sdk ~> 0.17.0`
  - `codex_sdk ~> 0.16.0`
  - `gemini_cli_sdk ~> 0.2.0`
  - `amp_sdk ~> 0.5.0`
- Updated runtime missing-provider guidance to point at the current SDK ranges.
- `PromptRunner.Scaffold` now derives provider dependencies from the configured
  provider plus any per-prompt provider overrides instead of hardcoding a stale
  provider list into generated `run_prompts.exs` files.
- Synced Prompt Runner's config/session surface to the current ASM and SDK
  contracts:
  - normalizes provider-native and legacy permission aliases onto the shared
    runner modes `:default | :auto | :bypass | :plan`
  - rejects stale provider-specific inputs such as Codex `sandbox` and
    `ask_for_approval` at config load instead of failing later during runtime
  - preserves inherited root `timeout` and `permission_mode` values when a
    prompt override switches providers without redefining those fields
- Refreshed README, provider docs, getting-started docs, and example docs to
  reflect the 0.5.0 provider matrix and current install instructions.
- Expanded the shipped example packs and standalone `run_prompts.exs` scripts
  to exercise all four providers: Claude, Codex, Amp, and Gemini.
- Example setup scripts now reset their workspaces before seeding, so repeated
  example runs start from a deterministic clean repo state.
- Local sibling-repo development now requires explicit opt-in via
  `PROMPT_RUNNER_USE_LOCAL_DEPS=1`, and Hex packaging tasks ignore that opt-in
  so release builds never emit `path:` dependencies.
- Hex package builds now exclude generated example runtime artifacts such as
  seeded repos, workspaces, logs, and progress files.

### Fixed

- Removed stale Prompt Runner Claude model remapping so current short aliases
  such as `sonnet` resolve through `claude_agent_sdk` instead of an outdated
  hardcoded model id.
- Aligned recovery-related prompt-control behavior with the actual current
  runtime support in the local ASM/SDK stack:
  - Claude no longer defaults `max_turns` to `1` when the runner does not set it
  - Amp rejects unsupported prompt controls such as `system_prompt` and
    `max_turns` instead of silently accepting dead config
  - Gemini SDK startup now uses `approval_mode: :yolo` without duplicating the
    deprecated `yolo: true` flag
- Corrected the live example provider contracts:
  - Codex now stays on the supported ASM shared permission modes
    (`:default | :bypass | :plan`) instead of the invalid shared `:auto` path
  - Amp examples now use the current `amp-1` model instead of a Claude model id
  - Gemini examples allow the current provider-native shell tool name
    `run_shell_command`
  - multi-repo prompts now describe the real working-directory and sibling-repo
    layout used at runtime

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
- Stream error tracking now preserves structured `provider_error` payloads from `:error_occurred`/`:run_failed` events instead of flattening to generic strings
- `return_error` now renders concise summaries by default and prints provider stderr detail only when `log_meta: :full`
- Updated `guides/configuration.md` with new rendering, timeout, and CLI confirmation options
- Updated `guides/providers.md` with Codex reasoning effort and CLI confirmation details
- Updated `guides/getting-started.md` with studio mode and new CLI flags
- Updated README with rendering modes section, new CLI options, and error detail behavior

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

[0.9.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nshkrdotcom/prompt_runner_sdk/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/prompt_runner_sdk/releases/tag/v0.1.0
