# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Acmex Placeholder LLC.

# ─── Template init ceremony ──────────────────────────────────────────
#
# One-shot: rewrites the placeholder identity to yours, renames paths,
# refreshes the lockfile, regenerates hooks, asserts zero placeholders
# remain, and removes tools/init. Run once, right after creating the
# repo from the template.
#
#   just init name=myproj org=my-org entity="My Org LLC" author="Me <me@example.com>"
#
# Optional: domain=<contact domain> (defaults to <org>.example).
init name org entity="" author="" domain="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d tools/init ]; then
        printf "\033[0;31m❌ tools/init not found — this repo looks initialized already.\033[0m\n"
        exit 1
    fi
    ARGS=(--name "{{ name }}" --org "{{ org }}")
    [ -n "{{ entity }}" ] && ARGS+=(--entity "{{ entity }}")
    [ -n "{{ author }}" ] && ARGS+=(--author "{{ author }}")
    [ -n "{{ domain }}" ] && ARGS+=(--domain "{{ domain }}")
    cargo run --release --manifest-path tools/init/Cargo.toml -- "${ARGS[@]}"

