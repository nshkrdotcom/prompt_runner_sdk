#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "${base_dir}/workspace" "${base_dir}/.prompt_runner"

echo "Cleaned: ${base_dir}"
