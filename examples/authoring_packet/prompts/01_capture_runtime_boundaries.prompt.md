---
id: "01"
phase: 1
name: "Capture runtime boundaries"
template: "from-adr"
targets:
  - "app"
commit: "docs: add runtime boundaries summary"
references:
  - "docs/adr-001-runtime-boundaries.md"
required_reading:
  - "docs/adr-001-runtime-boundaries.md"
context_files:
  - "workspace/README.md"
depends_on: []
verify:
  files_exist:
    - "RUNTIME_BOUNDARIES.md"
  contains:
    - path: "RUNTIME_BOUNDARIES.md"
      text: "Prompt Runner owns packet orchestration."
    - path: "RUNTIME_BOUNDARIES.md"
      text: "Agent Session Manager owns provider session lifecycle."
  changed_paths_only:
    - "RUNTIME_BOUNDARIES.md"
simulate:
  attempts:
    - messages:
        - "Reading ADR 001 and drafting the packet-local runtime boundary summary."
      writes:
        - path: "RUNTIME_BOUNDARIES.md"
          text: |-
            # Runtime Boundaries
            - Prompt Runner owns packet orchestration.
            - Agent Session Manager owns provider session lifecycle.
            - Provider-specific behavior stays below Prompt Runner where possible.
---
# Capture runtime boundaries

## Required Reading

- `docs/adr-001-runtime-boundaries.md`

## Architecture Context

- The packet runtime should talk about repo outputs and verification contracts.
- Session lifecycle and provider event delivery belong below Prompt Runner.

## Mission

Read ADR 001 and create `RUNTIME_BOUNDARIES.md` in the target repo.

## Deliverables

- `RUNTIME_BOUNDARIES.md` summarizing the runtime boundary split

## Non-Goals

- Do not modify any other files.
- Do not change provider integrations.

## Verification Notes

- The file must exist.
- It must include the Prompt Runner and Agent Session Manager ownership lines.
- No other files should change.
