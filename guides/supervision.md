# Supervising A Long Run

A packet with thirty prompts, each sized for tens of minutes of model work, is
a run nobody watches continuously. Legacy packet mode provides
`mix prompt_runner watch` for that case.

```bash
mix prompt_runner watch demo
mix prompt_runner watch demo --interval 300
mix prompt_runner watch demo --once
mix prompt_runner watch demo --once --json
```

One line per interval:

```text
WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27
```

| Field | Meaning |
|-------|---------|
| `runner` | `UP` when `.prompt_runner/run.pid` names the process identity that acquired the run lock |
| `prompt` | id in the newest `prompt-*.log`, or `none` |
| `quiet` | minutes since the newest file mtime across the log directory and every configured repo |
| `repos` | number of repositories in the packet manifest |
| `dirty` | total `git status --porcelain` lines across those repositories |
| `commits` | total commits reachable from `HEAD` across those repositories |

Default interval is 900 seconds. `--once` emits a single sample and returns,
which is the form to use from a cron job or another supervisor.

## Why It Is Built This Way

Two mechanisms are deliberate, because the obvious implementations of both fail
silently in the direction of "healthy" — and silence from a health check is
indistinguishable from health.

### Liveness comes from a pid file, not a process-name match

The runner exclusively creates `.prompt_runner/run.pid` when a run starts and
removes it when that same run ends, including when it fails. A second run for
the packet is refused rather than overwriting the first lock. On Linux the file
also records `/proc` process start time, preventing a recycled PID from reading
as the original run.

The alternative — matching a process name or command line — matches *any*
process whose command line contains the pattern. That includes the supervisor's
own shell, and it includes a human running `ps | grep` to check. A supervisor
built that way reports a live run forever, including long after the run died.

The pid file is written only when the plan has a state directory, so API runs
using the in-memory runtime store stay free of filesystem side effects.

### Quiet time comes from mtimes, not from the event log

Prompt Runner emits two different JSONL event schemas depending on
`events_mode`:

```text
compact:  {"e":{"t":"tu"},"t":1786332318176}          epoch milliseconds
full:     {"data":{...},"ts":"2026-08-10T05:08:53Z"}  ISO 8601
```

A watcher that parses one of them reports zero elapsed time for the other,
which is exactly the situation the event stream exists to distinguish from a
hang. An mtime cannot be the wrong schema.

`watch` walks the packet's log directory and every configured repository and
takes the newest file mtime it finds. When there is nothing to measure it
prints `quiet=?min` rather than a fabricated `0`.

The walk skips `.git`, `_build`, `deps`, and `node_modules`. All four are
derived output or internal bookkeeping whose mtimes say nothing about whether a
session is making progress, and on a large repository they dominate the scan —
a build directory alone can outnumber the source tree by an order of magnitude.
Pruning them trades a rarer false "quiet" for a scan cheap enough to run on an
interval, and the 15-minute default absorbs the former.

That walk is still the only expensive thing `watch` does. On very large
repositories `--interval` is the lever.

### It decides nothing

`watch` has no failure model and no thresholds. It reports what is on the
machine and lets the reader judge. A watcher that greps for known failure
signatures only catches failures somebody predicted; liveness is exhaustive by
construction, because at any moment a run is either gone, advancing, or not
advancing, and there is no fourth case.

Reading the line: `runner=DOWN` means the run ended — check whether the last
prompt committed. A large `quiet` with `runner=UP` means the run is alive and
not advancing, which is the case worth waking up for.

## Running A Packet Unattended

```bash
tmux new -s packet
mix prompt_runner run demo --no-commit 2>&1 | tee run.log
```

In a second pane:

```bash
mix prompt_runner watch demo --interval 900
```

Start the run under `tmux` or an equivalent. A dropped connection kills the
provider subprocess.

`--no-commit` makes each session responsible for committing its own work, which
is the right arrangement when a prompt touches several repositories: the
runner's committer squashes a multi-repository change under one generated
message and never pushes. Pair it with the
[`repos_clean:`](verification-and-repair.md) verify clause, which is the gate
that holds those sessions to account.

## From Elixir

```elixir
{:ok, sample} = PromptRunner.Watch.sample("/path/to/demo")

sample.runner        # :up | :down
sample.quiet_minutes # integer | nil
sample.dirty

IO.puts(PromptRunner.Watch.format_line(sample))
```

`PromptRunner.Watch.run/2` is the loop; `sample/2` is the single measurement,
for embedding in a host application's own supervision.

## Operator Workspace Monitoring

Prepared workspaces have a separate bounded, evidence-producing monitor. Use a
workspace id (or omit it from an unambiguous related directory):

```bash
prompt_runner watch operator-packet --for 240m --every 10m --require-running --require-progress --progress-timeout 60m
```

This reads the durable run, journal, service cgroup, process lease, ordinary
prompt progress, and agent cursor heartbeat. It writes JSONL samples and a final
report below the workspace runtime's `acceptance/` directory. The explicit
`prompt_runner watch --workspace MANIFEST ...` form remains supported.

## When A Run Dies Mid-Packet

1. `mix prompt_runner status demo` — runtime state, attempt history, and the
   last verifier report per prompt.
2. Check whether the session committed. A dead session that committed did real
   work; a dead session with a dirty tree did not finish, and the tree is the
   evidence.
3. Do not `git reset --hard` to clean up. Read the diff — it is the most
   reliable record of where the session actually got to.
4. Re-run the single prompt: `mix prompt_runner run demo 07`.
5. If a prompt fails twice for a reasoning rather than a mechanical reason, the
   prompt is probably wrong. Fix the prompt, not the model.

`mix prompt_runner repair --packet demo 07` re-runs one prompt with the unmet
verifier items appended to its body. See
[Verification And Repair](verification-and-repair.md).
