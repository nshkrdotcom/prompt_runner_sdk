---
id: "01"
phase: 1
name: "Retry after provider capacity"
targets:
  - "app"
commit: "docs: add retry example output"
simulate:
  attempts:
    - messages:
        - "Simulating provider capacity saturation."
      error:
        kind: "provider_capacity"
        message: "Selected model is at capacity. Please try again."
    - messages:
        - "Simulating successful retry."
      writes:
        - path: "retry.txt"
          text: "retry ok"
verify:
  files_exist:
    - "retry.txt"
  contains:
    - path: "retry.txt"
      text: "retry ok"
  changed_paths_only:
    - "retry.txt"
---
# Retry after provider capacity

## Mission

Create `retry.txt` with exactly one line:

`retry ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
