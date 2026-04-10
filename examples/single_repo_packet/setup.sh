#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${base_dir}/workspace"
runtime_dir="${base_dir}/.prompt_runner"

rm -rf "${workspace_dir}" "${runtime_dir}"
mkdir -p "${workspace_dir}"

git -C "${workspace_dir}" init -q
git -C "${workspace_dir}" config user.name "PromptRunner Example"
git -C "${workspace_dir}" config user.email "example@example.com"

printf "# Single Repo Example\n\nSeed workspace for the packet demo.\n" > "${workspace_dir}/README.md"
git -C "${workspace_dir}" add README.md
git -C "${workspace_dir}" commit -q -m "chore: seed example workspace"

echo "Workspace ready: ${workspace_dir}"
