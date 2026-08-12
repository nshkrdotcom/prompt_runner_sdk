# API Guide

The 0.12.0 API is packet-first. The CLI is a convenience layer over these
modules.

## Packet And Profile APIs

Initialize the profile store:

```elixir
{:ok, _paths} = PromptRunner.Profile.init()
{:ok, templates} = PromptRunner.Template.list()
```

Create and inspect profiles:

```elixir
{:ok, profile} =
  PromptRunner.Profile.create("codex-fast", %{
    "provider" => "codex",
    "model" => "gpt-5.6-luna",
    "reasoning_effort" => "high"
  })

{:ok, _same_profile} = PromptRunner.Profile.load(profile.name)
{:ok, names} = PromptRunner.Profile.list()
```

Create a packet and add a repo:

```elixir
{:ok, packet} =
  PromptRunner.Packet.new("demo",
    root: "/tmp",
    profile: "simulated-default",
    prompt_template: "from-adr",
    provider: "simulated",
    model: "simulated-demo",
    recovery: %{
      "resume_attempts" => 2,
      "retry" => %{"max_attempts" => 3, "base_delay_ms" => 0, "max_delay_ms" => 0},
      "repair" => %{"enabled" => true, "max_attempts" => 2}
    }
  )

{:ok, packet} = PromptRunner.Packet.add_repo(packet.root, "app", "/path/to/repo", default: true)
```

Create a prompt file:

```elixir
{:ok, _path} =
  PromptRunner.Packets.create_prompt(packet.root, %{
    "id" => "01",
    "phase" => 1,
    "name" => "Capture runtime boundaries",
    "targets" => ["app"],
    "commit" => "docs: add runtime boundaries summary"
  })
```

The packet's `prompt_template` is applied automatically. You can also override
it per prompt with:

```elixir
{:ok, _path} =
  PromptRunner.Packets.create_prompt(packet.root, %{
    "id" => "02",
    "phase" => 1,
    "name" => "Create execution checklist",
    "targets" => ["app"],
    "commit" => "docs: add execution checklist",
    "template" => "from-adr"
  })
```

Inspect packet health:

```elixir
{:ok, preflight_report} = PromptRunner.preflight(packet.root)
{:ok, doctor_report} = PromptRunner.Packet.doctor(packet.root)
{:ok, preflight_report} = PromptRunner.Packet.preflight(packet.root)
{:ok, explain_report} = PromptRunner.Packet.explain(packet.root)
```

`preflight` is the runtime readiness gate that checks packet-local repo paths
and git readiness before provider execution.

## Authoring Hazards

`PromptRunner.PacketLint.lint/2` is the static hazard gate behind
`mix prompt_runner packet lint`:

```elixir
{:ok, report} = PromptRunner.PacketLint.lint(packet.root, strict: true)

report.pass?
report.errors
report.warnings

Enum.each(report.findings, fn finding ->
  IO.puts("#{finding.severity} #{finding.file} #{finding.kind}: #{finding.message}")
end)
```

The only option is `:strict`, which promotes every warning to an error. See
[Packet Linting](linting.md).

## Planning And Running

```elixir
{:ok, plan} = PromptRunner.plan(packet.root, interface: :cli)
{:ok, run} = PromptRunner.run(packet.root, interface: :cli)
```

Useful plan fields:

- `plan.prompts`
- `plan.options`
- `plan.runtime_store`
- `plan.committer`
- `plan.state_dir`
- `plan.config`

### Selecting what runs

```elixir
# exactly these, in this order
PromptRunner.run(packet.root, interface: :cli, prompts: ["02", "03"])

# every prompt whose recorded status is not `completed`, in order —
# including ones earlier than the furthest one that finished
PromptRunner.run(packet.root, interface: :cli, remaining: true)

# resume from last_completed + 1; steps over an earlier failure and names it
PromptRunner.run(packet.root, interface: :cli, continue: true)
```

Under `remaining: true`, each prompt's verify contract is evaluated before the
provider is invoked; one that already passes is marked completed with no
session and records `session_ran: false`. `verify_first: true | false` states
it explicitly. See `PromptRunner.run/2`.

## Embedded Use

API calls default to an in-memory runtime store plus a no-op committer:

```elixir
{:ok, run} =
  PromptRunner.run(packet.root,
    provider: :codex,
    model: "gpt-5.6-luna",
    runtime_store: :memory,
    committer: :noop
  )
```

That keeps embedded use free of surprise filesystem writes and git commits
unless you opt in.

For deterministic recovery demos:

```elixir
{:ok, run} =
  PromptRunner.run(packet.root,
    provider: :simulated,
    runtime_store: :memory,
    committer: :noop
  )
```

## Repair And Status

```elixir
{:ok, status} = PromptRunner.status(packet.root)
{:ok, repaired_run} = PromptRunner.repair(packet.root, prompt: "01", interface: :cli)
```

`PromptRunner.status/1` returns the packet runtime state from
`.prompt_runner/state.json`.

## Supervision

`PromptRunner.Watch.sample/2` collects one measurement of a packet's
supervision facts, for embedding in a host application's own monitoring:

```elixir
{:ok, sample} = PromptRunner.Watch.sample(packet.root)

sample.runner        # :up | :down, from .prompt_runner/run.pid
sample.prompt        # id in the newest prompt log, or nil
sample.quiet_minutes # minutes since the newest mtime, or nil
sample.dirty         # uncommitted paths across configured repos
sample.commits

IO.puts(PromptRunner.Watch.format_line(sample))
# WATCH 16:57Z runner=UP prompt=11 quiet=0min repos=3 dirty=0 commits=27
```

`PromptRunner.Watch.run/2` is the interval loop used by
`mix prompt_runner watch`. The runner writes `.prompt_runner/run.pid` for the
duration of any run with a file-backed state directory and removes it on exit,
including on failure. See [Supervising A Long Run](supervision.md).

## Deterministic Verification

Run verification without executing prompts:

```elixir
{:ok, plan} = PromptRunner.plan(packet.root, interface: :cli)
{:ok, reports} = PromptRunner.Verifier.verify(plan)
```

Or verify one prompt:

```elixir
prompt = Enum.find(plan.prompts, &(&1.num == "01"))
report = PromptRunner.Verifier.verify_prompt(plan, prompt)

report.pass?
report.failures  # each with :kind, :repo, :details
```

`PromptRunner.Verifier.contract_keys/0` returns the clauses the verifier
evaluates, and `contract_items/1` renders a contract as checklist labels.

## Observer Callbacks

Supported callbacks:

- `on_event`
- `on_prompt_started`
- `on_prompt_completed`
- `on_prompt_failed`
- `on_run_completed`

```elixir
{:ok, run} =
  PromptRunner.run(packet.root,
    on_event: fn event -> IO.inspect(event.type) end
  )
```

## PubSub Bridge

```elixir
callback = PromptRunner.Observer.PubSub.callback(MyApp.PubSub, "prompt_runner:runs")

{:ok, run} =
  PromptRunner.run(packet.root,
    on_event: callback
  )
```
