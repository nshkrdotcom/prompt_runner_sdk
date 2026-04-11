---
id: "06"
phase: 2
name: "Verifier override after provider error"
targets:
  - "app"
commit: "docs: add verifier override example output"
simulate:
  attempts:
    - messages:
        - "Simulating a late provider runtime error after the output is already correct."
      writes:
        - path: "override.txt"
          text: "override ok"
      error:
        kind: "provider_runtime_claim"
        message: "Final transport flush failed after writing output."
verify:
  files_exist:
    - "override.txt"
  contains:
    - path: "override.txt"
      text: "override ok"
  changed_paths_only:
    - "override.txt"
---
# Verifier override after provider error

## Mission

Create `override.txt` with exactly one line:

`override ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
