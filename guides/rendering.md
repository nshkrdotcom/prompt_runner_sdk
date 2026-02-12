# Rendering Modes

PromptRunner uses AgentSessionManager's rendering pipeline to display LLM
session output. Three modes are available:

## Studio Mode (Recommended)

Studio mode produces clean, human-readable output matching the quality of
the Claude Code and Codex CLIs.

    log_mode: :studio

### Tool Output Verbosity

Control how much tool output is shown:

    tool_output: :summary   # One-line summaries (default)
    tool_output: :preview   # Summary + last 3 lines
    tool_output: :full      # Complete output

### Example Output

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      Prompt 01: PubSub Integration
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      ● gpt-5.3-codex session started

        I'll implement the PubSub integration. Let me read the
        existing sink modules first.

      ✓ Read lib/rendering/sink.ex (72 lines)
      ✓ Read lib/rendering/sinks/callback.ex (50 lines)

        Now I'll create the test file.

      ✓ Wrote test/pubsub_sink_test.exs (138 lines)
      ✓ Ran: mix test test/pubsub_sink_test.exs (exit 0, 3.2s)

      ● Session complete (end_turn) — 847/312 tokens, 6 tools

      ✓ Prompt 01 completed

## Compact Mode

Dense single-line token format for log monitoring:

    log_mode: :compact

    r+ gpt-5.3-codex >> Implementing... t+Read t-Read tr:{...} r-:end

## Verbose Mode

Line-by-line bracketed format for debugging:

    log_mode: :verbose

    [run_started] model=gpt-5.3-codex
    [tool_call_started] name=Read id=tu_001
    [tool_call_completed] name=Read output=...
    [run_completed] stop_reason=end_turn tokens=847/312

## CLI Overrides

    elixir run_prompts.exs --log-mode studio --tool-output preview

## Failure Detail Toggle

Use `log_meta` to control terminal error detail:

    log_meta: :none   # summary only (default)
    log_meta: :full   # include provider stderr details when available

`log_meta: :full` only affects failure rendering and does not change normal
token/tool event rendering.
