---
id: "04"
phase: 1
name: "Retry after remote auth claim"
targets:
  - "app"
commit: "docs: add auth retry example output"
simulate:
  attempts:
    - messages:
        - "Simulating a remote auth claim that clears on retry."
      error:
        kind: "provider_auth_claim"
        message: "Provider reported an auth handshake failure."
    - messages:
        - "Simulating successful retry after auth claim."
      writes:
        - path: "auth.txt"
          text: "auth ok"
verify:
  files_exist:
    - "auth.txt"
  contains:
    - path: "auth.txt"
      text: "auth ok"
  changed_paths_only:
    - "auth.txt"
---
# Retry after remote auth claim

## Mission

Create `auth.txt` with exactly one line:

`auth ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
