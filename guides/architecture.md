# Architecture

Prompt Runner has one core runtime and several entrypoints layered on top.

## Entry Points

- `PromptRunner.run/2`
- `PromptRunner.plan/2`
- `PromptRunner.validate/2`
- `PromptRunner.run_prompt/2`
- `PromptRunner.CLI`
- `Mix.Tasks.PromptRunner`
- `run_prompts.exs`

## Core Runtime Flow

```text
input
  -> RunSpec
  -> Source.load/2
  -> Plan.build/1
  -> Runner
  -> RuntimeStore + Committer + Rendering
```

## Sources

- `PromptRunner.Source.DirectorySource`
- `PromptRunner.Source.LegacyConfigSource`
- `PromptRunner.Source.ListSource`
- `PromptRunner.Source.SinglePromptSource`

All sources normalize their input into prompt structs plus commit metadata.

## Runtime Stores

- `PromptRunner.RuntimeStore.FileStore`
- `PromptRunner.RuntimeStore.MemoryStore`
- `PromptRunner.RuntimeStore.NoopStore`

The runtime store owns progress tracking and log destination selection.

## Committers

- `PromptRunner.Committer.GitCommitter`
- `PromptRunner.Committer.NoopCommitter`
- `PromptRunner.Committer.CallbackCommitter`

CLI and legacy runs default to git commits.
API runs default to no-op commits.

## Rendering

Streaming output is handled through `agent_session_manager` renderers and sinks:

- compact
- verbose
- studio

PromptRunner adds lifecycle callbacks and observer hooks around that stream.
