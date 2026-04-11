---
id: "05"
phase: 1
name: "Retry after model unavailable"
targets:
  - "app"
commit: "docs: add config retry example output"
simulate:
  attempts:
    - messages:
        - "Simulating a temporary model-unavailable claim."
      error:
        kind: "provider_config_claim"
        message: "Selected model is temporarily unavailable."
    - messages:
        - "Simulating another temporary model-unavailable claim."
      error:
        kind: "provider_config_claim"
        message: "Selected model is temporarily unavailable."
    - messages:
        - "Simulating successful retry after model becomes available again."
      writes:
        - path: "config.txt"
          text: "config ok"
verify:
  files_exist:
    - "config.txt"
  contains:
    - path: "config.txt"
      text: "config ok"
  changed_paths_only:
    - "config.txt"
---
# Retry after model unavailable

## Mission

Create `config.txt` with exactly one line:

`config ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
