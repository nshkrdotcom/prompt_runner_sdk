---
id: "03"
phase: 2
name: "Resume after transport drop"
targets:
  - "app"
commit: "docs: add resume example output"
simulate:
  attempts:
    - messages:
        - "Simulating a recoverable transport interruption."
      error:
        kind: "protocol_error"
        message: "WebSocket protocol error: Connection reset without closing handshake"
  resume:
    messages:
      - "Simulating successful provider-session resume."
    writes:
      - path: "resumed.txt"
        text: "resumed ok"
verify:
  files_exist:
    - "resumed.txt"
  contains:
    - path: "resumed.txt"
      text: "resumed ok"
  changed_paths_only:
    - "resumed.txt"
---
# Resume after transport drop

## Mission

Create `resumed.txt` with exactly one line:

`resumed ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
