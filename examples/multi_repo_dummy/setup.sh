#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repos_dir="${base_dir}/repos"
progress_file="${base_dir}/.progress"
logs_dir="${base_dir}/logs"

rm -rf "${repos_dir}"
rm -f "${progress_file}"
rm -rf "${logs_dir}"
mkdir -p "${repos_dir}"

create_repo() {
  local name="$1"
  local repo_dir="${repos_dir}/${name}"

  mkdir -p "${repo_dir}"
  git -C "${repo_dir}" init -q
  git -C "${repo_dir}" config user.name "PromptRunner Dummy"
  git -C "${repo_dir}" config user.email "dummy@example.com"

  printf "# %s\n\nSeed repo for multi-repo prompt demo.\n" "${name}" > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -q -m "chore: seed ${name} repo"

  echo "Created repo: ${repo_dir}"
}

create_repo "alpha"
create_repo "beta"

echo "Repos ready under: ${repos_dir}"
