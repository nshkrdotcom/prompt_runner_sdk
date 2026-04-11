#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "$ROOT/.prompt_runner" "$ROOT/workspace"

echo "Cleaned $ROOT"
