# API Guide

The 0.7.0 API is packet-first. The CLI is a convenience layer over these
modules.

## Packet And Profile APIs

Initialize the profile store:

```elixir
{:ok, _paths} = PromptRunner.Profile.init()
```

Create and inspect profiles:

```elixir
{:ok, profile} =
  PromptRunner.Profile.create("codex-fast", %{
    "provider" => "codex",
    "model" => "gpt-5.4",
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
    provider: "simulated",
    model: "simulated-demo",
    retry_attempts: 2,
    auto_repair: true
  )

{:ok, packet} = PromptRunner.Packet.add_repo(packet.root, "app", "/path/to/repo", default: true)
```

Create a prompt file:

```elixir
{:ok, _path} =
  PromptRunner.Packets.create_prompt(packet.root, %{
    "id" => "01",
    "phase" => 1,
    "name" => "Create hello file",
    "targets" => ["app"],
    "commit" => "docs: add hello file"
  })
```

Inspect packet health:

```elixir
{:ok, doctor_report} = PromptRunner.Packet.doctor(packet.root)
{:ok, explain_report} = PromptRunner.Packet.explain(packet.root)
```

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

## Embedded Use

API calls default to an in-memory runtime store plus a no-op committer:

```elixir
{:ok, run} =
  PromptRunner.run(packet.root,
    provider: :codex,
    model: "gpt-5.4",
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
```

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
