---
id: "01"
phase: 1
name: "Create hello file"
targets:
  - "app"
commit: "docs: add hello file"
verify:
  files_exist:
    - "hello.txt"
  contains:
    - path: "hello.txt"
      text: "Hello from Prompt Runner"
  changed_paths_only:
    - "hello.txt"
---
# Create hello file

## Mission

You are running in the packet example repository.

Create `hello.txt` with exactly one line:

`Hello from Prompt Runner`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
