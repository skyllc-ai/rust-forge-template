# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC.

# === Brownfield adoption: try it, keep it, or undo it ================
#
# adopt.sh applies the whole scaffolding as COMMITS on the branch
# `adopt/rust-forge-scaffolding`, created from your clean tree. That
# geometry makes the trial reversible: keeping it is a normal PR merge,
# and undoing it is deleting a branch. These recipes wrap both sides.

# Show where the adoption trial stands.
adopt-status:
    #!/usr/bin/env bash
    set -euo pipefail
    if git rev-parse --verify adopt/rust-forge-scaffolding >/dev/null 2>&1; then
        printf "\033[0;34madopt branch exists:\033[0m adopt/rust-forge-scaffolding\n"
        base=$(git config --get forge.adoptBase 2>/dev/null || echo "?")
        printf "  base branch recorded: %s\n" "$base"
        printf "  commits on it:\n"
        git log --oneline "${base}..adopt/rust-forge-scaffolding" 2>/dev/null | sed 's/^/    /' || true
        printf "\033[0;36m  keep it:  open a PR from the branch (or merge it)\033[0m\n"
        printf "\033[0;36m  drop it:  just adopt-undo\033[0m\n"
    else
        printf "\033[0;36mno adoption trial in progress (branch adopt/rust-forge-scaffolding absent)\033[0m\n"
    fi

# Undo the ENTIRE adoption trial: back to the base branch, delete the
# adopt branch, and unwind the repo-local config the flow created
# (core.hooksPath). What deliberately survives: installed tools (machine
# software you may want anyway), your SSH key + its GitHub registration
# (user-level artifacts), and repo-local signing config if you ran
# `just setup-signing` (harmless and useful; unset the four
# gpg.format/user.signingkey/commit.gpgsign/tag.gpgsign keys yourself if
# you want it gone). Your code returns bit-for-bit to the pre-adoption
# state.
adopt-undo:
    #!/usr/bin/env bash
    set -euo pipefail
    git rev-parse --verify adopt/rust-forge-scaffolding >/dev/null 2>&1 \
        || { printf "\033[1;33mnothing to undo: branch adopt/rust-forge-scaffolding does not exist\033[0m\n"; exit 1; }
    base=$(git config --get forge.adoptBase 2>/dev/null || echo "")
    if [[ -z "$base" ]]; then
        printf "\033[1;33mno recorded base branch; tell me where to return: git switch <branch> then delete the adopt branch manually\033[0m\n"
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        printf "\033[1;33muncommitted changes present; commit or stash them first (undo must not eat work)\033[0m\n"
        exit 1
    fi
    printf "\033[0;34mundoing the adoption trial: returning to '%s'\033[0m\n" "$base"
    git switch "$base"
    git branch -D adopt/rust-forge-scaffolding
    # Unwind repo-local config the flow created
    if [[ "$(git config --get core.hooksPath 2>/dev/null)" == "scripts/hooks" ]]; then
        git config --unset core.hooksPath
        printf "  \033[0;32mcore.hooksPath unset\033[0m\n"
    fi
    git config --unset forge.adoptBase 2>/dev/null || true
    printf "\033[0;32mdone: repository restored to pre-adoption state (branch deleted).\033[0m\n"
    printf "\033[0;36mkept on purpose: installed tools, your SSH key/GitHub registration,\033[0m\n"
    printf "\033[0;36mand any repo-local signing config from 'just setup-signing'.\033[0m\n"
    printf "\033[0;36mchanged your mind again? just re-run adopt.sh any time.\033[0m\n"
