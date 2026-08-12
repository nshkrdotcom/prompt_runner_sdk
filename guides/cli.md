# CLI Guide

Prompt Runner exposes the same CLI through three entry points:

- `mix prompt_runner ...`
- `mix run run_prompts.exs -- ...`
- `./prompt_runner ...` after `mix escript.build`

All commands operate on a packet directory. If you omit the directory, Prompt
Runner uses the current working directory.

## Setup Commands

Initialize the global profile store:

```bash
mix prompt_runner init
mix prompt_runner template list
```

Create and inspect profiles:

```bash
mix prompt_runner profile new codex-fast --provider codex --model gpt-5.6-luna --reasoning high
mix prompt_runner profile list
```

## Packet Authoring Commands

Create a packet:

```bash
mix prompt_runner packet new demo \
  --profile simulated-default \
  --provider simulated \
  --model simulated-demo \
  --repo app=/path/to/repo \
  --default-repo app \
  --prompt-template from-adr

mix prompt_runner prompt new 01 \
  --packet demo \
  --phase 1 \
  --name "Capture runtime boundaries" \
  --targets app \
  --commit "docs: add runtime boundaries summary"

mix prompt_runner checklist sync demo
```

Packet-local templates can override the home-scoped templates created by
`init`. List visible templates for a packet with:

```bash
mix prompt_runner template list demo
```

Use the packet manifest's `recovery:` block for the full policy surface. The
CLI flags are convenience shorthands for common resume/retry/repair defaults.

## Packet Inspection Commands

```bash
mix prompt_runner packet explain demo      # resolved manifest metadata
mix prompt_runner packet lint demo         # authoring hazards
mix prompt_runner packet doctor demo       # authoring gaps
mix prompt_runner packet preflight demo    # runtime readiness
```

The four are complementary and in increasing order of what they touch:

- `explain` prints the packet's repos, phases, and resolved options as JSON.
- `lint` is static. It reports constructs that load, run, and silently produce
  a wrong answer: an id that does not match its filename prefix, a verify
  command with no `timeout`, a target naming a repo that does not exist. Exits
  non-zero on errors. See [Packet Linting](linting.md).
- `doctor` reports authoring gaps — no prompts, no default repo, a prompt with
  no targets or no verifier items, scaffold placeholders left in a body.
- `preflight` is the runtime gate used before provider execution. It checks
  packet repo paths and git readiness, prints JSON, exits non-zero when the run
  should not start, and is called automatically by `run` unless
  `--skip-preflight` is explicit.

`packet lint` flags:

- `--strict` — promote every warning to an error, which is what CI wants
- `--json` — machine-readable report

## Execution Commands

List and plan:

```bash
mix prompt_runner list demo
mix prompt_runner plan demo
mix prompt_runner plan demo --provider simulated --model simulated-demo
```

`plan` accepts the same override flags as `run`, so it reports the plan `run`
would actually build. Before 0.9.0 it parsed no flags at all and always
reported the packet's own provider and model.

Run everything:

```bash
mix prompt_runner run demo
mix prompt_runner run demo --skip-preflight
```

Preview without starting a provider:

```bash
mix prompt_runner run demo --dry-run
```

`--dry-run` prints, per prompt, the resolved provider, model, working
directory, permission mode, target repos, and the commit message that would be
used. It starts nothing.

Run only deterministic contracts, without opening a provider or changing
packet progress:

```bash
prompt_runner verify demo 01 02
prompt_runner verify --packet demo --workspace workspace.yml --json
```

The workspace form binds logical repositories and installed contract artifacts
to the current operator's independent workspace.

When the prepared workspace manifest declares its default packet, the id is the
whole target:

```bash
prompt_runner plan operator-packet --remaining
prompt_runner verify operator-packet 01
prompt_runner start operator-packet --remaining --no-commit
prompt_runner status operator-packet
prompt_runner control events operator-packet
prompt_runner watch operator-packet
prompt_runner stop operator-packet
```

All explicit `--workspace MANIFEST --packet PACKET_DIR` forms remain supported.
See [Operator Workspaces](workspaces.md) for the strict packet binding.

Run specific prompts:

```bash
mix prompt_runner run demo 01 02
mix prompt_runner run demo --phase 2
```

## Resuming

```bash
mix prompt_runner run demo --remaining
```

`--remaining` runs every prompt whose recorded status is not `completed`, in
order. That includes prompts *earlier* than the furthest one that finished: if
03 failed while 04 succeeded, `--remaining` runs 03 and 05, and says so.

A prompt with no recorded status is remaining — the absence of a record is not
evidence of success. A missing progress store is a new run. An existing store
that cannot be read or parsed stops selection instead of silently turning a
resume into a full rerun.

When `--remaining` selects nothing, the run says so rather than exiting zero in
silence.

### Intentionally replacing a run generation

A failed or interrupted run is bound to the packet content it started with.
Changing a prompt, dependency edge, or contract makes an ordinary resume fail
closed. After reviewing and committing that packet change, start a fresh run
generation explicitly while preserving completed-prompt progress:

```bash
mix prompt_runner run demo --remaining --new-run
```

The prior run directory and append-only journal remain intact and receive a
`run_superseded` record naming the new identity. `--new-run` is never inferred
from a fingerprint mismatch; without the flag the mismatch remains an error.

### Pre-flight verification

Under `--remaining`, each prompt's verify contract is evaluated *before* the
provider is invoked. If it already passes, the prompt is marked completed with
no session, and its state records `session_ran: false` and
`source: "preflight_verify"`. This is what makes a prompt idempotent and a
resume cheap: finished work re-verifies in seconds instead of being re-done.

Two contracts are never pre-flighted:

- one with no evaluable clause, which would pass vacuously
- one containing `changed_paths_only`, which reads `git status --porcelain` and
  so passes vacuously against a clean tree — including the clean tree that
  exists before any session has run

`--verify-first` and `--no-verify-first` state it explicitly either way. Naming
a prompt id is a request to run it, so pre-flight is off for explicit ids
unless `--verify-first` is given.

An agent-owned packet never preflight-completes an unrecorded prompt from its
structural contract. `--remaining` still excludes IDs already recorded as
completed, but stale files alone cannot prevent the coding agent from running.
After a normal incomplete return, the runner opens a fresh session for the same
prompt until its structural evidence passes.

### `--continue`

`--continue` is an API option, not a CLI switch. It resumes from
`last_completed + 1`, so it steps over any earlier prompt that failed or never
ran. When it does, the runner names the prompts being skipped and points at
`--remaining`. Its behaviour is unchanged — some callers want exactly that.

Let each session own its commits:

```bash
mix prompt_runner run demo --no-commit
```

Repair a failed prompt from stored verifier state:

```bash
mix prompt_runner repair --packet demo 02
```

Print packet-local runtime status JSON:

```bash
mix prompt_runner status demo
```

For a prepared operator workspace, address it by manifest id and get a compact
human summary:

```bash
prompt_runner status operator-packet
```

`prompt_runner status` with no argument discovers the workspace when the
current directory is related to exactly one prepared manifest, declared source
checkout, or independent clone. It refuses an ambiguous match and asks for the
id. The report shows only relevant dimensions: prompt counts for multi-prompt
runs, iteration progress for an agent-controlled loop, and attempt details for
retry or repair.

Use the structured form for automation:

```bash
prompt_runner status operator-packet --json
prompt_runner status --workspace /path/to/workspace.yml --json
```

The explicit `--workspace` form remains the deterministic interface for
service scripts. Workspace ids and current-directory discovery come from
operator-owned reference records written by `workspace prepare`, not from
environment-specific aliases or recursive filesystem search.

## Agent-Controlled Linear Runs

When the packet enables `agent_control`, the running provider receives these
iteration-scoped commands:

```bash
prompt_runner agent-control progress --cursor P09R.2 --unit C --summary "generic runtime ownership is in progress"
prompt_runner agent-control continue
prompt_runner agent-control repeat --reason "P09R.2 unit B is complete; next is unit C runtime ownership"
prompt_runner agent-control finish --reason "the packet objective is complete"
prompt_runner agent-control blocked --reason "exact external blocker"
```

The provider publishes progress repeatedly; a human only runs `status`.
Progress is nonterminal and never consumes the first-wins directive. The
commands are rejected outside a live controlled invocation. `finish` does
not trust the provider's claim: Prompt Runner runs the packet-level
`completion_verify` contract and starts a fresh iteration with its failures if
the request was premature. See [Agent-Controlled Linear Runs](agent-control.md).

## Supervision

```bash
mix prompt_runner watch demo
mix prompt_runner watch demo --interval 300
mix prompt_runner watch demo --once --json
```

One compact line per interval:

```text
WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27
```

Liveness comes from the `.prompt_runner/run.pid` file the runner writes for the
duration of a run, and quiet time comes from file mtimes. See
[Supervising A Long Run](supervision.md) for why both matter.

## Useful Execution Flags

`run` and `plan` both accept:

- `--provider`
- `--model`
- `--log-mode`
- `--log-meta`
- `--events-mode`
- `--tool-output`
- `--thinking` (`show` | `hide`)
- `--diff` (`none` | `stat` | `full`)
- `--cli-confirmation`
- `--runtime-store`
- `--committer`
- `--skip-preflight`
- `--no-commit`
- `--dry-run`
- `--all`
- `--remaining`
- `--verify-first` / `--no-verify-first`
- `--phase N`

`watch` accepts:

- `--interval SECONDS` (default 900)
- `--once`
- `--json`

`packet lint` accepts:

- `--strict`
- `--json`

`packet new` accepts:

- `--repo NAME=PATH` (repeatable)
- `--default-repo`
- `--prompt-template`
- `--profile`
- `--provider`
- `--model`
- `--reasoning`
- `--permission`
- `--resume-attempts`
- `--retry-attempts`
- `--retry-base-delay-ms`
- `--retry-max-delay-ms`
- `--retry-jitter`
- `--auto-repair`
- `--repair-attempts`
- `--cli-confirmation`

`prompt new` accepts:

- `--packet`
- `--phase`
- `--name`
- `--targets`
- `--commit`
- `--template`

Example:

```bash
mix prompt_runner run demo \
  --provider codex \
  --model gpt-5.6-luna \
  --log-mode compact \
  --cli-confirmation require
```

## Escript

Build once:

```bash
mix escript.build
```

Then use the same commands:

```bash
./prompt_runner run demo
./prompt_runner watch demo --once
./prompt_runner status demo
```
