#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$ROOT/workspace"

rm -rf "$ROOT/.prompt_runner" "$WORKSPACE"
mkdir -p "$WORKSPACE"

git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" config user.name "Prompt Runner Example"
git -C "$WORKSPACE" config user.email "prompt-runner@example.com"
printf "# Simulated Recovery Example\n" >"$WORKSPACE/README.md"
git -C "$WORKSPACE" add README.md
git -C "$WORKSPACE" commit -q -m "initial"

echo "Workspace ready: $WORKSPACE"
