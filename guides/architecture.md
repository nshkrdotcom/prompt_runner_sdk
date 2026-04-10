# Architecture

Prompt Runner 0.7.0 is organized around one packet runtime with both CLI and
SDK entry points.

## Runtime Flow

```text
packet dir
  -> PromptRunner.Packet / PromptRunner.Source.PacketSource
  -> PromptRunner.Plan
  -> PromptRunner.Runner
  -> PromptRunner.Session
  -> PromptRunner.Verifier
  -> PromptRunner.Runtime + RuntimeStore + Committer
```

## Core Concepts

- `PromptRunner.Profile`
  home-scoped defaults
- `PromptRunner.Packet`
  packet manifest loader and doctor surface
- `PromptRunner.Packets`
  prompt creation and checklist sync
- `PromptRunner.Plan`
  fully resolved execution plan
- internal runner pipeline
  execution, retry, repair, and completion logic
- `PromptRunner.Verifier`
  deterministic completion contracts
- `PromptRunner.Runtime`
  packet-local attempt history and status state

## Completion Model

Prompt Runner no longer treats provider success as completion.

Completion is owned by the verifier:

- provider success + verifier pass => complete
- provider success + verifier fail => repair
- transient provider failure + verifier pass => complete
- terminal provider or policy failure => fail

## Recovery Model

Prompt Runner prefers provider-native session continuation for recoverable
transport failures. Repair is a separate higher-level step driven by unmet
verifier items.
