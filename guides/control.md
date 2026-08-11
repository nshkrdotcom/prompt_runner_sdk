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

A `run_ref` is `{packet_dir, run_id}`. Explicit ids rather than an implicit
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
```

## Changing the view, mid-run

```elixir
:ok = PromptRunner.Control.set_view(run_ref, %{tool_output: :full})
```

```bash
prompt_runner control view demo --tool-output full
prompt_runner control view demo --log-mode studio --thinking hide
```

| setting | values | what it changes |
|---------|--------|-----------------|
| `log_mode` | `compact`, `verbose`, `studio` | which renderer is running |
| `tool_output` | `none`, `summary`, `preview`, `full` | how much of a tool's output is shown |
| `thinking` | `show`, `hide` | whether a reasoning model's thinking is printed |
| `diff` | `none`, `stat`, `full` | how file changes are rendered |

`:ok` means the request was accepted for delivery, not that it has been applied.
The runner consumes requests **at event boundaries** — never mid-event, because
a view that changed halfway through rendering an event produces output belonging
to neither setting — and records the outcome in the control log. That asynchrony
is deliberate: it is what stops an in-VM caller from quietly getting a
privileged synchronous path the CLI does not have.

A `log_mode` change replaces the renderer. Whatever the outgoing renderer had
accumulated — counters, an open line — goes with it.

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
