---
id: "09"
phase: 4
name: "Resume after transport timeout"
targets:
  - "app"
commit: "docs: add timeout resume example output"
simulate:
  attempts:
    - messages:
        - "Simulating a recoverable transport timeout."
      error:
        kind: "transport_timeout"
        message: "Transport timed out waiting for stream events."
  resume:
    messages:
      - "Simulating successful resume after transport timeout."
    writes:
      - path: "timeout-resumed.txt"
        text: "timeout resumed ok"
verify:
  files_exist:
    - "timeout-resumed.txt"
  contains:
    - path: "timeout-resumed.txt"
      text: "timeout resumed ok"
  changed_paths_only:
    - "timeout-resumed.txt"
---
# Resume after transport timeout

## Mission

Create `timeout-resumed.txt` with exactly one line:

`timeout resumed ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
