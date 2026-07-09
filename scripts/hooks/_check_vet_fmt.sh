#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# Format-drift detector for cargo-vet's `supply-chain/` store.
#
# cargo-vet owns the format of `audits.toml`, `config.toml`, and
# `imports.lock` (see docs/architecture/dev-flow-implementation-plan.md
# § tool-routing and `.taplo.toml` for the taplo-side of the story).
# `cargo vet check` hard-fails at pre-push if the store drifts; this
# script is the pre-commit counterpart.
#
# `cargo vet fmt` is mutating-only in 0.10.x (no `--check` mode), so
# we snapshot the store, run the reformatter, and compare:
#   * if the reformatter produced the same bytes, we restore the
#     pre-fmt state so the working tree is untouched and exit 0;
#   * if any file changed, we restore the pre-fmt state (so the
#     operator's working tree is untouched) and exit 1 with a hint.
#
# Revisit once upstream cargo-vet adds a `fmt --check` mode; this
# script can then shrink to a single subprocess call.

set -euo pipefail

# Resolve to the workspace root — cargo vet has to run where
# `supply-chain/` lives, and the pre-commit hook cwd is already the
# workspace root, but make it explicit for standalone invocations.
cd "$(git rev-parse --show-toplevel)"

snap_dir=$(mktemp -d)
trap 'rm -rf -- "$snap_dir"' EXIT

cp -R supply-chain "$snap_dir/"
cargo vet fmt >/dev/null 2>&1

if diff -rq supply-chain "$snap_dir/supply-chain" >/dev/null 2>&1; then
    # No drift: nothing to do; trap cleans up $snap_dir.
    exit 0
fi

# Drift found — restore pre-fmt state so the operator's working tree
# is untouched, then fail with an actionable hint.
rm -rf supply-chain
mv "$snap_dir/supply-chain" .

echo "supply-chain format drift detected."
echo "Run: cargo vet fmt && git add supply-chain/ && re-commit"
exit 1
