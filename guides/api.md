# API Guide

The public API is centered on four functions:

```elixir
PromptRunner.plan/2
PromptRunner.validate/2
PromptRunner.run/2
PromptRunner.run_prompt/2
```

## Input Shapes

`PromptRunner.run/2` accepts:

- a prompt directory
- a legacy config path
- a list of `%PromptRunner.Prompt{}`
- a raw prompt string via `run_prompt/2`

## Planning

```elixir
{:ok, plan} =
  PromptRunner.plan("./prompts",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

Useful fields on `plan`:

- `plan.prompts`
- `plan.source`
- `plan.runtime_store`
- `plan.committer`
- `plan.state_dir`
- `plan.config`

## Running

```elixir
{:ok, run} =
  PromptRunner.run("./prompts",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

Single prompt:

```elixir
{:ok, run} =
  PromptRunner.run_prompt(
    "Create hello.txt with a greeting.",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

## Defaults In API Mode

API mode defaults to:

- in-memory runtime state
- `NoopCommitter`
- no implicit `.prompt_runner/` directory

That makes it suitable for workers, web requests, and background jobs.

## Observer Callbacks

Supported callbacks:

- `on_event`
- `on_prompt_started`
- `on_prompt_completed`
- `on_prompt_failed`
- `on_run_completed`

Example:

```elixir
{:ok, run} =
  PromptRunner.run("./prompts",
    target: "/repo",
    provider: :claude,
    model: "haiku",
    on_event: fn event -> IO.inspect(event.type) end
  )
```

Raw streaming events and PromptRunner lifecycle events are both delivered to
`on_event`.

## PubSub Bridge

```elixir
callback = PromptRunner.Observer.PubSub.callback(MyApp.PubSub, "prompt_runner:runs")

{:ok, run} =
  PromptRunner.run("./prompts",
    target: "/repo",
    provider: :claude,
    model: "haiku",
    on_event: callback
  )
```

## Explicit Prompt Structs

```elixir
prompts = [
  %PromptRunner.Prompt{
    num: "01",
    phase: 1,
    sp: 3,
    name: "Schema",
    body: "Add the missing schema field.",
    commit_message: "feat: add missing schema field"
  }
]

{:ok, run} =
  PromptRunner.run(prompts,
    target: "/repo",
    provider: :claude,
    model: "haiku"
  )
```
