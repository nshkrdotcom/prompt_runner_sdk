# Rendering Modes

Prompt Runner uses `agent_session_manager` renderers and sinks for streaming
output.

## Modes

- `compact`
  dense terminal output for routine runs
- `verbose`
  one event per line for debugging
- `studio`
  richer prompt headers and tool summaries

## Related Packet Options

- `log_mode`
- `log_meta`
- `events_mode`
- `tool_output`

## Tool Output Levels

- `summary`
- `preview`
- `full`

## Failure Detail Levels

- `none`
- `full`

With `full`, provider stderr detail is printed when available.

## Event Logs

When the runtime store is file-backed, Prompt Runner writes packet-local logs
to:

```text
.prompt_runner/logs/
```

`events_mode` controls JSONL event emission:

- `compact`
- `full`
- `off`
