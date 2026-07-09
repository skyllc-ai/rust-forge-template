# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.

# Show current version.
version:
    @printf "\033[0;34m📋 Current version:\033[0m\n"
    @cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "acmex-cli") | .version'

# ── Binary release (Path B) — `just ship` cuts it ───────────────────
#
# ACMEX ships its BINARY on your command, not automatically.  release-plz
# only versions the publishable leaf libs — it never drives binary
# releases for the application crates.  The release lives in your normal flow:
#
#   1.  just ship            # validate (Phase 1) → bump → commit →
#                            #   open auto-merging release/vX.Y.Z PR (Phase 2)
#   2.  (PR auto-merges once its CI is green; the merge fires
#        release-auto-trigger.yml → release.yml builds the binaries)
#
# `just ship` Phase 2 bumps the lockstep `[workspace.package].version`
# (patch) ONLY after Phase 1 validation passes — code is verified clean
# before the version moves.  Merging the release/vX.Y.Z PR dispatches
# release.yml's 15-platform build automatically (added 2026-06-12 after
# v0.5.121 merged with no binaries — the old manual `release-tag` step
# was forgotten).  `release-tag` remains the manual fallback for
# re-cuts or a failed dispatch.  A normal merge to `main` still
# triggers no release — that is the manual-on-demand design.

# Retired R5 stub — version bumps now happen inside `just ship` Phase 2.
version-bump:
    @printf "\033[0;36m💡 Version bumps are part of 'just ship' now (Phase 2, patch).\033[0m\n"
    @printf "\033[0;36m   Binaries build automatically once the release PR merges (release-auto-trigger.yml).\033[0m\n"

# Manual FALLBACK after a `just ship` release PR merge — the normal
# path is automatic (release-auto-trigger.yml dispatches release.yml on
# merge).  Use for re-cuts or if the auto-dispatch failed:
# tag main → build binaries.
release-tag:
    #!/usr/bin/env bash
    set -euo pipefail
    branch=$(git branch --show-current)
    [ "$branch" = "main" ] || { printf "\033[0;31m❌ run from main (you are on %s)\033[0m\n" "$branch"; exit 1; }
    git fetch origin main --quiet
    git pull --ff-only origin main --quiet
    ver=$(cargo metadata --format-version 1 --no-deps | jq -r '.packages[] | select(.name=="acmex-cli") | .version')
    tag="v${ver}"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        printf "\033[0;31m❌ tag %s already exists\033[0m\n" "$tag"; exit 1
    fi
    git tag -s "$tag" -m "Release $tag"
    git push origin "$tag" --quiet
    printf "\n\033[0;32m✅ Tagged %s and pushed — release.yml is building the binaries.\033[0m\n" "$tag"
    printf "\033[0;36m   Watch: just release-watch   ·   Status: just release-status\033[0m\n"

# Build dev binary.
build:
    @printf "\033[0;34m🔨 Building dev binary (FAST-FAIL)...\033[0m\n"
    cargo build --workspace

# Build release binary.
build-release:
    @printf "\033[0;34m🔨 Building optimized release binary...\033[0m\n"
    @printf "\033[1;33m⚠️  This will take significantly longer than dev builds\033[0m\n"
    cargo build --release --workspace

# Build and install all binaries locally.
