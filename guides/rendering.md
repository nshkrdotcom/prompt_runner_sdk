# Rendering Modes

Prompt Runner uses `agent_session_manager` renderers and sinks for streaming
output.

## Modes

### `:compact`

Dense single-line status output for fast local iteration.

### `:verbose`

One event per line for debugging event streams.

### `:studio`

Readable CLI-grade output with prompt headers, tool summaries, and completion
status.

## Tool Output Levels

Studio mode supports:

- `:summary`
- `:preview`
- `:full`

## Failure Detail Levels

`log_meta` controls failure detail:

- `:none`
- `:full`

With `:full`, provider stderr detail is printed when available.

## Event Logs

`events_mode` controls JSONL event logging when a file-backed runtime store is
used:

- `:compact`
- `:full`
- `:off`

API runs using `MemoryStore` do not create file-backed event logs by default.

## Example

```elixir
PromptRunner.run("./prompts",
  target: "/repo",
  provider: :claude,
  model: "haiku",
  log_mode: :studio,
  tool_output: :summary
)
```
