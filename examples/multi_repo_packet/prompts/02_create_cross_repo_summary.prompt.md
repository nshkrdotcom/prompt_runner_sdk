---
id: "02"
phase: 2
name: "Create cross repo summary"
targets:
  - "alpha"
commit: "docs(alpha): add cross repo summary"
verify:
  files_exist:
    - repo: "alpha"
      path: "CROSS_REPO_SUMMARY.md"
  contains:
    - repo: "alpha"
      path: "CROSS_REPO_SUMMARY.md"
      text: "alpha ok"
    - repo: "alpha"
      path: "CROSS_REPO_SUMMARY.md"
      text: "beta ok"
  changed_paths_only:
    - repo: "alpha"
      path: "CROSS_REPO_SUMMARY.md"
---
# Create cross repo summary

## Mission

You are running in the `alpha` repository. The sibling `beta` repository is
available at `../beta`.

Read `NOTES.md` in the current repo and `../beta/NOTES.md` in the sibling repo.

Create `CROSS_REPO_SUMMARY.md` in the current repo with exactly these lines:

```text
# Cross Repo Summary

alpha ok
beta ok
```

Do not modify any other files. Do not run tests. Respond with exactly `ok`.
