---
id: "02"
phase: 2
name: "Create execution checklist"
template: "from-adr"
targets:
  - "app"
commit: "docs: add execution checklist"
references:
  - "docs/adr-001-runtime-boundaries.md"
  - "docs/adr-002-recovery-contract.md"
required_reading:
  - "docs/adr-001-runtime-boundaries.md"
  - "docs/adr-002-recovery-contract.md"
context_files:
  - "workspace/RUNTIME_BOUNDARIES.md"
depends_on:
  - "01"
verify:
  files_exist:
    - "EXECUTION_CHECKLIST.md"
  contains:
    - path: "EXECUTION_CHECKLIST.md"
      text: "Define verifier-owned completion contracts."
    - path: "EXECUTION_CHECKLIST.md"
      text: "Attach required reading to each prompt."
  changed_paths_only:
    - "EXECUTION_CHECKLIST.md"
simulate:
  attempts:
    - messages:
        - "Reading the ADRs plus the runtime boundary summary, then writing the execution checklist."
      writes:
        - path: "EXECUTION_CHECKLIST.md"
          text: |-
            # Execution Checklist
            - Define verifier-owned completion contracts.
            - Attach required reading to each prompt.
            - Use retries and repair based on verifier results.
---
# Create execution checklist

## Required Reading

- `docs/adr-001-runtime-boundaries.md`
- `docs/adr-002-recovery-contract.md`
- `workspace/RUNTIME_BOUNDARIES.md`

## Architecture Context

- The packet runtime needs clear execution boundaries.
- Recovery is driven by verifier results, not only provider success.

## Mission

Create `EXECUTION_CHECKLIST.md` in the target repo using the ADR decisions and
the runtime boundary summary from prompt `01`.

## Deliverables

- `EXECUTION_CHECKLIST.md` with actionable execution rules

## Non-Goals

- Do not modify any other files.
- Do not restate the ADRs verbatim.

## Verification Notes

- The file must exist.
- It must include the verifier-owned completion and required-reading lines.
- No other files should change.
