#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "${base_dir}/workspace"
rm -rf "${base_dir}/logs"
rm -f "${base_dir}/.progress"

echo "Cleaned: ${base_dir}/workspace ${base_dir}/logs ${base_dir}/.progress"
