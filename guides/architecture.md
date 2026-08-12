# Architecture

Prompt Runner 0.13.0 is organized around one packet runtime with both CLI and
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
- `PromptRunner.CompletionPolicy`
  packet-level verifier-owned or agent-owned completion semantics
- internal runner pipeline
  preflight, execution, retry, repair, and completion logic
- `PromptRunner.AgentControl`
  authenticated per-iteration directives for movement through a linear prompt
  sequence, plus an independent repeatable nonterminal progress record
- `PromptRunner.Verifier`
  deterministic completion contracts, with `Verifier.Doc` and
  `Verifier.ReposClean` implementing the artifact-quality and
  repository-discipline clauses
- `PromptRunner.Runtime`
  packet-local attempt history and status state
- `PromptRunner.Watch`
  supervision facts for a long unattended run

## Completion Model

Prompt Runner does not treat an unqualified provider success as completion.

Verifier-owned completion remains the backward-compatible default:

- provider success + verifier pass => complete
- provider success + verifier fail => repair, while the repair budget lasts
- transient provider failure + verifier pass => complete
- verifier fail with the repair budget spent => fail
- terminal provider or policy failure => fail

Every branch terminates. Repair is bounded by `recovery.repair.max_attempts`,
and the exhausted case fails with the unmet verifier items rather than
starting another attempt.

Agent-owned completion is an explicit packet alternative. The coding agent
runs and repairs executable QC inside its session; `verify.commands` is invalid
for the packet. Prompt Runner evaluates structural evidence only. A normal
return with incomplete structural evidence creates a durable incomplete
iteration and opens a fresh session for the same prompt with the unmet evidence
attached. The prompt is not terminally failed between sessions, so the
scheduler does not dependency-block its descendants prematurely. Completed IDs
remain durable resume facts, while structural files cannot preflight-complete
an unrecorded prompt.

An agent-controlled packet adds one linear transition after an ordinary prompt
iteration verifies: continue, repeat, finish, or blocked. Repeat opens a fresh
provider session on the same prompt. Finish is accepted only when the separate
packet-level completion contract passes. The agent never marks its own work
complete and never terminates the runner process.

Live project progress is deliberately not a fifth transition. Each controlled
invocation receives a separate authenticated progress path and may atomically
replace its own cursor record many times. Terminal request storage stays
exclusive and first-wins. Workspace status accepts only a record matching the
current durable run and prompt, and identifies a retained prior-iteration
record as stale.

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
