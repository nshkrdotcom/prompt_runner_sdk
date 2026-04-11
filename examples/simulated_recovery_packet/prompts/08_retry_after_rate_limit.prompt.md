---
id: "08"
phase: 4
name: "Retry after provider rate limit"
targets:
  - "app"
commit: "docs: add rate limit retry example output"
simulate:
  attempts:
    - messages:
        - "Simulating a retryable remote rate limit."
      error:
        kind: "provider_rate_limit"
        message: "Rate limit exceeded. Please retry later."
    - messages:
        - "Simulating successful retry after rate limit backoff."
      writes:
        - path: "rate-limit.txt"
          text: "rate limit ok"
verify:
  files_exist:
    - "rate-limit.txt"
  contains:
    - path: "rate-limit.txt"
      text: "rate limit ok"
  changed_paths_only:
    - "rate-limit.txt"
---
# Retry after provider rate limit

## Mission

Create `rate-limit.txt` with exactly one line:

`rate limit ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
