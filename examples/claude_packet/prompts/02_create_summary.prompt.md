---
id: "02"
phase: 2
name: "Create summary file"
targets:
  - "app"
commit: "docs: add summary file"
verify:
  files_exist:
    - "SUMMARY.md"
  contains:
    - path: "SUMMARY.md"
      text: "Summary"
    - path: "SUMMARY.md"
      text: "Hello from Prompt Runner"
  changed_paths_only:
    - "SUMMARY.md"
---
# Create summary file

## Mission

Read `hello.txt`.

Create `SUMMARY.md` with exactly these lines:

```text
# Summary

Hello from Prompt Runner
```

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
