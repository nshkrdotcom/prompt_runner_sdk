#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${base_dir}/workspace"
progress_file="${base_dir}/.progress"
logs_dir="${base_dir}/logs"

rm -rf "${workspace_dir}"
rm -f "${progress_file}"
rm -rf "${logs_dir}"
mkdir -p "${workspace_dir}"
git -C "${workspace_dir}" init -q
git -C "${workspace_dir}" config user.name "PromptRunner Simple"
git -C "${workspace_dir}" config user.email "simple@example.com"

printf "# Simple Example Workspace\n\nSeed workspace for the simple prompt demo.\n" > "${workspace_dir}/README.md"
git -C "${workspace_dir}" add README.md
git -C "${workspace_dir}" commit -q -m "chore: seed simple workspace"

echo "Workspace ready: ${workspace_dir}"
