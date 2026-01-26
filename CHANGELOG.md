# Changelog

## [0.1.1] - 2026-01-26

### Fixed

- Fixed single-repo commit path bug where `commit_single_repo` always committed to `config.project_dir` instead of the resolved target repository path. Now correctly passes repo name and path from `runner.ex` to `git.ex`.

### Changed

- Added `:inets` to extra_applications for OTP HTTP client support.
- `commit_single_repo/2` now accepts optional `repo_name` and `repo_path` parameters for explicit targeting.

### Dependencies

- Updated `ex_doc` from 0.39.3 to 0.40.0.
- Updated `finch` from 0.20.0 to 0.21.0.

## [0.1.0] - 2026-01-18

- Initial release.
- Prompt runner CLI with streaming output.
- Claude Agent SDK and Codex SDK support via a unified facade.
- Multi-repo prompt execution with per-repo commit messages.
- Example prompt sets for single-repo and multi-repo workflows.
