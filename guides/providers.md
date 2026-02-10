# Multi-Provider Setup

Prompt Runner SDK supports three LLM providers through [AgentSessionManager](https://hex.pm/packages/agent_session_manager). The `PromptRunner.Session` module starts the appropriate adapter, runs a single prompt, normalizes the event stream, and cleans up.

| Provider | Atom | Adapter | Description |
|----------|------|---------|-------------|
| Claude | `:claude` | `ClaudeAdapter` | Anthropic Claude models |
| Codex | `:codex` | `CodexAdapter` | OpenAI Codex models |
| Amp | `:amp` | `AmpAdapter` | Amp models |

## Choosing a Provider

Set the `provider` key in the `llm` section:

```elixir
%{
  model: "haiku",
  llm: %{provider: "claude"}
}
```

If `provider` is omitted, it defaults to `"claude"`.

## Per-Prompt Overrides

Switch providers for individual prompts using `prompt_overrides`:

```elixir
%{
  llm: %{
    provider: "claude",
    model: "haiku",
    prompt_overrides: %{
      "02" => %{provider: "codex", model: "gpt-5.3-codex"},
      "04" => %{provider: "amp"}
    }
  }
}
```

Prompts 01 and 03 use Claude (the default). Prompt 02 uses Codex. Prompt 04 uses Amp.

Overrides are deep-merged with the base config, so you only specify what changes.

## Provider Details

### Claude

Claude model aliases are resolved by `PromptRunner.Session`:

| Alias | Full Model ID |
|-------|---------------|
| `"haiku"` | `claude-haiku-4-5-20251001` |
| `"sonnet"` | `claude-sonnet-4-5-20250929` |
| `"opus"` | `claude-opus-4-6` |

Any other string is passed through as-is (e.g., `"claude-sonnet-4-5-20250929"`).

Claude supports `allowed_tools` and `permission_mode`:

```elixir
llm: %{
  provider: "claude",
  model: "haiku",
  permission_mode: :accept_edits,
  allowed_tools: ["Read", "Write", "Edit", "Bash"],
  claude_opts: %{
    # Additional options passed to ClaudeAdapter
  }
}
```

Claude uses `project_dir` as its `cwd` — the Claude CLI runs in that directory.

### Codex

Codex uses the `project_dir` as its working directory automatically. No extra cwd configuration needed.

```elixir
llm: %{
  provider: "codex",
  model: "gpt-5.3-codex",
  codex_opts: %{
    # Options passed to CodexAdapter
  },
  codex_thread_opts: %{
    # Thread-level options (sandbox, approval settings, etc.)
  }
}
```

Both `codex_opts` and `codex_thread_opts` are merged into the adapter options, with `adapter_opts` applied last.

### Amp

Amp also uses `project_dir` as its working directory:

```elixir
llm: %{
  provider: "amp",
  adapter_opts: %{
    # Options passed to AmpAdapter
  }
}
```

## Normalized Options

These options work across all providers. The Session module passes them to the appropriate adapter, which maps them to provider-specific SDK fields.

| Option | Claude | Codex | Amp |
|--------|--------|-------|-----|
| `permission_mode` | `--permission-mode` CLI flag | `full_auto` / `dangerously_bypass` | `dangerously_allow_all` |
| `max_turns` | `--max-turns N` (nil=unlimited) | `RunConfig` max_turns (nil=SDK default 10) | ignored (CLI-enforced) |
| `system_prompt` | `system_prompt` on Options | `base_instructions` on Thread.Options | stored in state |
| `sdk_opts` | merged into `ClaudeAgentSDK.Options` | merged into `Codex.Thread.Options` | merged into `AmpSdk.Types.Options` |

```elixir
llm: %{
  provider: "claude",
  model: "haiku",
  permission_mode: :dangerously_skip_permissions,
  max_turns: 10,
  system_prompt: "You are a code assistant. Be concise.",
  sdk_opts: [verbose: true]
}
```

Normalized options always take precedence over `sdk_opts`.

## adapter_opts

The `adapter_opts` map provides a provider-agnostic way to pass options to any adapter. It is merged *after* provider-specific options (`claude_opts`, `codex_opts`, `codex_thread_opts`):

```elixir
llm: %{
  provider: "claude",
  model: "sonnet",
  adapter_opts: %{max_tokens: 16384}
}
```

`adapter_opts` can be set at both the root config level and within the `llm` section. The `llm` value takes precedence.

## Event Format

`PromptRunner.Session` passes canonical AgentSessionManager events directly to the rendering pipeline. The rendering system (`AgentSessionManager.Rendering`) handles all event types uniformly regardless of which provider is in use:

| Canonical Event | Description |
|----------------|-------------|
| `:run_started` | Session started (model, session_id) |
| `:message_streamed` | Text content delta |
| `:tool_call_started` | Tool invocation started (tool_name, tool_input) |
| `:tool_call_completed` | Tool invocation finished (tool_name, tool_output) |
| `:token_usage_updated` | Token counts (input_tokens, output_tokens) |
| `:message_received` | Complete message received |
| `:run_completed` | Session completed (stop_reason) |
| `:run_failed` | Session failed (error_code, error_message) |
| `:run_cancelled` | Session cancelled |
| `:error_occurred` | Error during session (error_code, error_message) |

## Session Lifecycle

For each prompt execution, `Session.start_stream/2`:

1. Resolves the provider and builds an adapter spec (`{Module, opts}` tuple)
2. Delegates to `AgentSessionManager.StreamSession.start/1` which:
   - Starts an `InMemorySessionStore` automatically
   - Starts the adapter from the spec
   - Launches a task that calls `SessionManager.run_once/4`
   - Returns a lazy event stream with 120s idle timeout
3. Returns `{:ok, stream, close_fun, meta}`

The returned `close_fun` terminates the task, adapter, and store. There is no session persistence across prompts — each prompt gets a fresh session.

## Backward Compatibility

The legacy `sdk` key still works everywhere `provider` is accepted:

```elixir
# Legacy (still supported)
llm: %{sdk: "claude_agent_sdk"}

# Current
llm: %{provider: "claude"}
```

See the [Configuration Reference](configuration.md) for the full alias table.
