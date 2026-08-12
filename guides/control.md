# Watching And Steering A Live Run

A packet run used to be a black box while it ran. You could read its output and
you could kill it, and that was the whole interface.

The control plane is the other half: a process-addressable API for reading a
run's state, following its events, and changing how it renders — without
attaching to the session, and from a different terminal, a different process,
or a different machine's dashboard.

`PromptRunner.Control` is that API. The `prompt_runner control` commands are one
consumer of it, written entirely against it. A Phoenix LiveView would use the
same functions.

## Addressing a run

A `run_ref` is `{store_root, run_id}`. The store root is a packet directory for
a legacy local run and a tagged external state root for an operator workspace.
Explicit ids rather than an implicit
"current run" cost nothing now and avoid a rewrite if the runner ever goes
concurrent.

```elixir
{:ok, run_ref} = PromptRunner.Control.current_run("packets/demo")
```

## Reading

```elixir
{:ok, snapshot} = PromptRunner.Control.snapshot(run_ref)

snapshot.prompt_id      #=> "03"
snapshot.attempt        #=> 2
snapshot.mode           #=> :repair
snapshot.elapsed_ms     #=> 412_330
snapshot.input_tokens   #=> 24_931
snapshot.view           #=> %{log_mode: :studio, tool_output: :summary, ...}
```

`snapshot/1` and `log/1` read files the runner writes. They never touch the
session, so polling them cannot slow, block, or crash the run.

```bash
prompt_runner control status demo
prompt_runner control status demo --json
prompt_runner control log demo --follow
prompt_runner control status operator-packet --json
prompt_runner control log operator-packet --follow
```

`control status` is the run snapshot. `control events` is the live/replayed
provider event stream. `control log` is narrower: it records operator control
requests such as view changes and steering, so it can legitimately print
nothing during an autonomous run.

For the normal human check, use the workspace rollup instead:

```bash
prompt_runner status operator-packet
# or, from a directory related to one prepared workspace:
prompt_runner status
```

That command combines run, selected-prompt progress, relevant loop/attempt
state, verifier result, provider activity, service state, and process lease in
one quiet report. `control status --json` remains the lower-level live snapshot
for dashboards and debugging; `prompt_runner status ... --json` is the complete
workspace reconciliation schema.

To watch provider activity rather than operator requests:

```bash
prompt_runner control events operator-packet
```

## Following events

```elixir
{:ok, ref} = PromptRunner.Control.subscribe(run_ref, self())

receive do
  {:prompt_runner_event, ^ref, event} -> event["type"]
  {:prompt_runner_control, ^ref, {:run_finished, status}} -> status
end
```

Events arrive exactly as they were written, so maps with string keys. A
subscription ends on its own when the run finishes or the subscribing process
dies; `unsubscribe/2` ends it earlier.

`from: :current` delivers only what arrives after subscribing; the default
replays the run from its first event and then follows.

```bash
prompt_runner control events demo
prompt_runner control events demo --from current --json
prompt_runner control events operator-packet --from current --json
```

## Changing the view, mid-run

```elixir
:ok = PromptRunner.Control.set_view(run_ref, %{tool_output: :full})
```

```bash
prompt_runner control view demo --tool-output full
prompt_runner control view demo --log-mode studio --thinking hide
prompt_runner control view operator-packet --tool-output full
```

| setting | values | what it changes |
|---------|--------|-----------------|
| `log_mode` | `compact`, `verbose`, `studio` | which renderer is running |
| `tool_output` | `none`, `summary`, `preview`, `full` | how much of a tool's output is shown |
| `thinking` | `show`, `hide` | whether a reasoning model's thinking is printed |
| `diff` | `none`, `stat`, `full` | how file changes are rendered (see below) |

`:ok` means the request was accepted for delivery, not that it has been applied.
The runner consumes requests **at event boundaries** — never mid-event, because
a view that changed halfway through rendering an event produces output belonging
to neither setting — and records the outcome in the control log. That asynchrony
is deliberate: it is what stops an in-VM caller from quietly getting a
privileged synchronous path the CLI does not have.

A `log_mode` change replaces the renderer. Whatever the outgoing renderer had
accumulated — counters, an open line — goes with it.

## Steering

```elixir
:ok = PromptRunner.Control.steer(run_ref, "check dependency_sources.exs before you keep editing mix files")
```

```bash
prompt_runner control steer demo "you're down a rabbit hole; check dependency_sources.exs first"
prompt_runner control steer operator-packet "check dependency_sources.exs first"
```

Steering changes *how* the agent works toward an **unchanged** definition of
done. The verify contract is untouched: the prompt still passes or fails on
exactly the criteria it started with. That is what makes steering safe to allow
freely, and what makes amendment a different verb.

### Two lanes, two mechanisms

| lane | stdin | how a steer arrives |
|------|-------|---------------------|
| `claude`, `codex`, `amp`, `cursor`, `antigravity` | closed at start | the turn is interrupted and the same provider thread is resumed with the steer as its next prompt |

Which one applies is the provider profile's own transport fact —
`CliSubprocessCore.ProviderProfile.accepts_input_after_start?/1` — not a list of
provider names, and not a caller's choice. On the resume lanes the agent keeps
its full context: same thread, no protocol change, nothing re-derived.

### A steer has its own budget

`recovery.max_steers` (default 3), per prompt, per run. It exists because on a
resume lane a steer *is* a fresh provider invocation, and a person who steers
three times and walks away has created three calls nothing was counting.

A steer never consumes and never resets `retry.max_attempts` or
`repair.max_attempts`. Those bound the run's own attempts to satisfy a
contract; a steer is not one of those. Exhausting `max_steers` is a **logged
refusal**, not a run failure — the run carries on unsteered.

### A steer is recorded, and is never evidence

Two separate things.

**Never evidence.** A contract asserting a document contains X is not satisfied
by a human having said "put X in the doc". The verifier sees what the session
produced, not what it was told.

**Always recorded**, in two places. On the control log, with its attempt
number; and as an append-only intervention artifact, one object per steer —
timestamp, prompt, attempt, author, text, lane, and delivery mechanism. A
legacy local run stores it at
`packet/.prompt_runner/interventions/<prompt>.jsonl`. A workspace run stores it
under the operator's external runtime, so issuing a steer cannot dirty or write
through to the packet author's checkout.

The prompt's result records `steered`, `steer_count`, and the path to the
artifact, so a human-guided result is distinguishable from an autonomous one —
flagged, not disqualified.

## Seeing what changed on disk

`diff` decides how a file change is rendered, and there are two genuinely
different cases behind it.

**The patch is in the event.** A Claude `Edit` carries `old_string` and
`new_string`; a `Write` carries the whole `content`. The diff is derivable from
the event alone — no filesystem access, no ambiguity, and it stays correct even
if the file changed again afterwards.

**Only the path is in the event.** A Codex `file_change` item and an
Antigravity `replace_file_content` name the file and the kind of change and
nothing else. The honest options are a `git diff` on that path, or a stat line.
A `git diff` is cheap and accurate *at the moment it runs* — but it shows the
file's current state, which after several edits in one turn is not the diff of
that one tool call.

**The rule: never present a reconstructed diff as if it were the tool's own
patch.**

| setting | patch in the event | path only |
|---------|--------------------|-----------|
| `none` | nothing | nothing |
| `stat` | `✓ Edited lib/a.ex  +12 −3` | `✓ Edited lib/a.ex` |
| `full` | the patch, indented | a `git diff`, labelled `(current state of lib/a.ex, not this call's change)` |

At `:full` the body is capped at a line budget and truncation is always
explicit — a truncated diff that looks complete is worse than no diff.

```bash
prompt_runner control view demo --diff full
prompt_runner run demo --log-mode studio --diff full
```

## Amendment — changing what "done" means

Steering leaves the contract alone. Amendment does not, and it is the one
capability here that can make a completed prompt mean something other than what
the packet says. So it is governed more tightly.

```bash
prompt_runner control contract demo 03
prompt_runner control amend demo 03 --add-file lib/nshkr/foo.ex --reason "the work needs a module the packet author did not anticipate"
prompt_runner control relax demo 03 --drop contains --reason "the requirement was wrong" --confirm

prompt_runner control contract operator-packet 03
prompt_runner control amend operator-packet 03 \
  --add-file lib/nshkr/foo.ex --reason "the work needs this module"
```

Workspace-id contract commands require the manifest's optional default packet
binding. The explicit `--workspace workspace.yml --packet packet` forms remain
available and are required when no binding is declared. Other workspace control
reads and actions need only a prepared id and do not require a packet binding.

### Timing is part of the meaning

Claims in these programs are pre-registered by git commit timestamp precisely
so nobody can decide what they were proving after seeing the result. An
amendment that *weakens* a contract after a verify failure is exactly the move
pre-registration exists to prevent. So the record says which:

- `pre_verify` — before any verify attempt ran. Ordinary scope correction.
- `post_failure` — after a verify failure. Suspect by default.
- `post_success` — after a verify pass. Also after the fact, and named honestly
  rather than folded into either of the other two.

An amendment log that does not say *when, relative to verification*, is not an
audit trail. Both appear in the prompt's result.

### Asymmetric by design

Adding a requirement is routine — `amend`. Removing or weakening one is the
risky direction and takes a different verb, `relax`, with `--confirm`. Never a
different argument to the same command.

`--reason` is mandatory on both. An amendment with no stated reason is refused,
not defaulted.

### Run-local by default

The packet file stays authoritative and a re-run from clean state uses its
contract. `--persist` writes the change back, which is a separate explicit act
because a packet is a versioned artifact and editing it is a commit, not a side
effect.

### Diffable

```
  contract for 03

  pre_verify   add files_exist by ada — the work needs this module

    files_exist: README.md
  + files_exist: lib/nshkr/foo.ex
```

If you cannot show the diff, you do not have the audit. A prompt completed
under an amended contract records `amended`, the amendments themselves, and the
path to the log — so "completed" stays traceable to the contract actually
enforced.

## The control directory

```
packet/.prompt_runner/control/
  requests/     one file per command, consumed and deleted
  log.jsonl     append-only: every command, who, when, outcome
  snapshot.json rewritten at each event boundary
  events.jsonl  append-only canonical event stream for subscribers
```

A directory rather than a socket, for the first transport: no daemon, no port,
no supervision tree to get wrong. It works under `tee`, `nohup`, tmux, and with
no terminal at all. It survives the runner dying — a snapshot written by a run
that was killed still says which prompt it was on. It is per-packet, so two
concurrently running programs cannot cross wires. And it is trivially
inspectable when something goes wrong.

Nothing arriving through this transport is ever fatal to a run. A file that is
not JSON, a command the runner does not know, a request naming a run that has
since ended — each is logged with its reason, deleted, and stepped over.

A run that keeps no state on disk — an in-memory API run — writes no control
directory at all.

## The audit trail

Every command that reaches the plane gets a log entry, including the refused
ones. A refusal that leaves no trace is indistinguishable from a command that
was never sent.

```elixir
{:ok, entries} = PromptRunner.Control.log(run_ref)

Enum.map(entries, &{&1.command, &1.outcome, &1.author, &1.reason})
#=> [{"set_view", :applied, "ada", nil},
#=>  {"set_view", :rejected, "ada", "tool_output does not take \"everything\"; ..."}]
```
