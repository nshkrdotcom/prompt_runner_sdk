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

The two modes emit different schemas, which matters to anything that reads the
files:

```text
compact:  {"e":{"t":"tu"},"t":1786332318176}          epoch milliseconds
full:     {"data":{...},"ts":"2026-08-10T05:08:53Z"}  ISO 8601
```

Do not judge whether a session did work from the terminal counters — a verified
run that wrote a file has reported `--- 5 events, 0 tools ---`. Read the event
log or the repository. `mix prompt_runner watch` deliberately measures activity
by file mtime rather than by parsing either schema. See
[Supervising A Long Run](supervision.md).

A run with a file-backed store also writes `.prompt_runner/run.pid` for its
duration, so a supervisor can check liveness without matching process names.
