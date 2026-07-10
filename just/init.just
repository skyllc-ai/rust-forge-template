# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC.

# ─── Template init ceremony ──────────────────────────────────────────
#
# One-shot: rewrites the placeholder identity to yours, renames paths,
# refreshes the lockfile, regenerates hooks, asserts zero placeholders
# remain, and removes tools/init. Run once, right after creating the
# repo from the template.
#
#   just init myproj my-org "My Org LLC" "Me <me@example.com>"
#
# Arguments are POSITIONAL: name org [entity] [author] [domain] [license].
# (`just` treats key=value tokens as raw strings, so a name=myproj style
# call would arrive with the literal "name=" prefix - do not use it.)
# domain defaults to <org>.example; license defaults to MIT OR Apache-2.0.
init name org entity="" author="" domain="" license="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d tools/init ]; then
        printf "\033[0;31m❌ tools/init not found - this repo looks initialized already.\033[0m\n"
        exit 1
    fi
    ARGS=(--name "{{ name }}" --org "{{ org }}")
    [ -n "{{ entity }}" ] && ARGS+=(--entity "{{ entity }}")
    [ -n "{{ author }}" ] && ARGS+=(--author "{{ author }}")
    [ -n "{{ domain }}" ] && ARGS+=(--domain "{{ domain }}")
    [ -n "{{ license }}" ] && ARGS+=(--license "{{ license }}")
    cargo run --release --manifest-path tools/init/Cargo.toml -- "${ARGS[@]}"

