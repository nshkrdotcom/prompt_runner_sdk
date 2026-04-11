---
id: "02"
phase: 1
name: "Repair incomplete work"
targets:
  - "app"
commit: "docs: add repair example output"
simulate:
  attempts:
    - messages:
        - "Simulating a superficially successful but incomplete answer."
      writes:
        - path: "hello.txt"
          text: "hello"
    - messages:
        - "Simulating a repair pass that only fixes missing verifier items."
      writes:
        - path: "hello.meta.txt"
          text: "meta"
verify:
  files_exist:
    - "hello.txt"
    - "hello.meta.txt"
  changed_paths_only:
    - "hello.txt"
    - "hello.meta.txt"
---
# Repair incomplete work

## Mission

Create both of these files:

- `hello.txt` with exactly one line: `hello`
- `hello.meta.txt` with exactly one line: `meta`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
