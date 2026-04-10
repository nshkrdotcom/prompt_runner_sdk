---
id: "01"
phase: 1
name: "Create repo notes"
targets:
  - "alpha"
  - "beta"
commit: "docs: add repo notes"
verify:
  files_exist:
    - repo: "alpha"
      path: "NOTES.md"
    - repo: "beta"
      path: "NOTES.md"
  contains:
    - repo: "alpha"
      path: "NOTES.md"
      text: "alpha ok"
    - repo: "beta"
      path: "NOTES.md"
      text: "beta ok"
  changed_paths_only:
    - repo: "alpha"
      path: "NOTES.md"
    - repo: "beta"
      path: "NOTES.md"
---
# Create repo notes

## Mission

You are running in the `alpha` repository. The sibling `beta` repository is
available at `../beta`.

Do the following:

1. In the current repo, create or update `NOTES.md` with exactly one line:
   `alpha ok`
2. In the sibling repo, create or update `../beta/NOTES.md` with exactly one
   line: `beta ok`

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
