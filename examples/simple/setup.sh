#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${base_dir}/workspace"

if [ -d "${workspace_dir}/.git" ]; then
  echo "Workspace already exists: ${workspace_dir}"
  exit 0
fi

mkdir -p "${workspace_dir}"
git -C "${workspace_dir}" init -q
git -C "${workspace_dir}" config user.name "PromptRunner Simple"
git -C "${workspace_dir}" config user.email "simple@example.com"

printf "# Simple Example Workspace\n\nSeed workspace for the simple prompt demo.\n" > "${workspace_dir}/README.md"
git -C "${workspace_dir}" add README.md
git -C "${workspace_dir}" commit -q -m "chore: seed simple workspace"

echo "Workspace ready: ${workspace_dir}"
