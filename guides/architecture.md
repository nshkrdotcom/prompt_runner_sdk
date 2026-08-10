# Architecture

Prompt Runner 0.9.0 is organized around one packet runtime with both CLI and
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
  packet manifest loader, runtime preflight, and doctor surface
- `PromptRunner.PacketLint`
  static authoring-hazard analysis
- `PromptRunner.Packets`
  prompt creation and checklist sync
- `PromptRunner.Plan`
  fully resolved execution plan
- internal runner pipeline
  preflight, execution, retry, repair, and completion logic
- `PromptRunner.Verifier`
  deterministic completion contracts, with `Verifier.Doc` and
  `Verifier.ReposClean` implementing the artifact-quality and
  repository-discipline clauses
- `PromptRunner.Runtime`
  packet-local attempt history and status state
- `PromptRunner.Watch`
  supervision facts for a long unattended run

## Completion Model

Prompt Runner no longer treats provider success as completion.

Completion is owned by the verifier:

- provider success + verifier pass => complete
- provider success + verifier fail => repair, while the repair budget lasts
- transient provider failure + verifier pass => complete
- verifier fail with the repair budget spent => fail
- terminal provider or policy failure => fail

Every branch terminates. Repair is bounded by `recovery.repair.max_attempts`,
and the exhausted case fails with the unmet verifier items rather than
starting another attempt.

## Recovery Model

Prompt Runner prefers provider-native session continuation for recoverable
transport failures. Repair is a separate higher-level step driven by unmet
verifier items.

## Run Bounds

`PromptRunner.Session` derives every time bound from the single `timeout` key:
the stream timeout, the transport timeout, the derived stream idle timeout, and
ASM's `run_deadline_ms`. An unset `timeout` means the seven-day emergency
bound on all four, not ASM's 600s default for the run deadline. See the
[Packet Manifest Reference](configuration.md).

## Observability

A run with a file-backed state directory writes `.prompt_runner/run.pid` for
its duration, `.prompt_runner/state.json` for attempt and verifier history, and
`.prompt_runner/logs/` for per-prompt transcripts and JSONL events.
`PromptRunner.Watch` reads the first and third of those. See
[Supervising A Long Run](supervision.md).
