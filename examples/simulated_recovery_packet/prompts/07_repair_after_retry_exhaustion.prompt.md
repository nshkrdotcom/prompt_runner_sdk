---
id: "07"
phase: 3
name: "Repair after retry exhaustion"
targets:
  - "app"
commit: "docs: add retry exhaustion repair example output"
recovery:
  retry:
    class_attempts:
      provider_runtime_claim: 1
simulate:
  attempts:
    - messages:
        - "Simulating an initial remote runtime failure with no workspace changes."
      error:
        kind: "provider_runtime_claim"
        message: "Unexpected remote runtime failure."
    - messages:
        - "Simulating retry exhaustion after partial workspace progress."
      writes:
        - path: "draft.txt"
          text: "draft"
      error:
        kind: "provider_runtime_claim"
        message: "Unexpected remote runtime failure."
    - messages:
        - "Simulating repair after retry exhaustion."
      writes:
        - path: "draft.meta.txt"
          text: "meta"
verify:
  files_exist:
    - "draft.txt"
    - "draft.meta.txt"
  changed_paths_only:
    - "draft.txt"
    - "draft.meta.txt"
---
# Repair after retry exhaustion

## Mission

Create both of these files:

- `draft.txt` with exactly one line: `draft`
- `draft.meta.txt` with exactly one line: `meta`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
