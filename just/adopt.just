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
        printf "\033[1;33muncommitted changes present; undo must not eat work:\033[0m\n"
        git status --short | sed 's/^/    /'
        printf "\033[1;33mcommit or stash them (or delete throwaway artifacts), then re-run\033[0m\n"
        exit 1
    fi
    printf "\033[0;34mundoing the adoption trial: returning to '%s'\033[0m\n" "$base"
    # The pipeline's own log dir is trial residue; safe to remove.
    command rm -rf build/logs 2>/dev/null || true
    rmdir build 2>/dev/null || true
    git switch "$base"
    git branch -D adopt/rust-forge-scaffolding
    # Unwind repo-local config the flow created
    if [[ "$(git config --get core.hooksPath 2>/dev/null)" == "scripts/hooks" ]]; then
        git config --unset core.hooksPath
        printf "  \033[0;32mcore.hooksPath unset\033[0m\n"
    fi
    git config --unset forge.adoptBase 2>/dev/null || true
    printf "\033[0;32mdone: repository restored to pre-adoption state (branch deleted).\033[0m\n"
    leftovers=$(git status --porcelain 2>/dev/null | head -5)
    if [[ -n "$leftovers" ]]; then
        printf "\033[1;33muntracked leftovers from the trial (delete if unwanted):\033[0m\n%s\n" "$leftovers"
    fi
    printf "\033[0;36mkept on purpose: installed tools, your SSH key/GitHub registration,\033[0m\n"
    printf "\033[0;36mand any repo-local signing config from 'just setup-signing'.\033[0m\n"
    printf "\033[0;36mchanged your mind again? just re-run adopt.sh any time.\033[0m\n"

# ─── Upgrading the machinery to the template's current state ──────────
#
# `adopt.sh --upgrade` (the same script that adopts) brings every
# machinery file, the lint posture, clippy.toml and the toolchain pin to
# the template's HEAD on a branch `forge/upgrade-<version>`: 3-way
# merges keep your edits, new lints land (at allow while your posture is
# still ratcheting), conflicts become <file>.forge-suggested. Runs in
# repos born from the template (`just init`) and in adopted ones alike.
# Set FORGE_TEMPLATE to a local checkout (or OWNER/REPO) to upgrade from
# something other than skyllc-ai/rust-forge-template's main.

# Upgrade the forge machinery to the template's current state (on a branch).
forge-upgrade *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    tmpl="${FORGE_TEMPLATE:-skyllc-ai/rust-forge-template}"
    if [[ -d "$tmpl/.git" ]]; then
        bash "$tmpl/adopt.sh" --upgrade --template "$tmpl" {{ FLAGS }}
    else
        curl -fsSL "https://raw.githubusercontent.com/${tmpl}/main/adopt.sh" | bash -s -- --upgrade --template "$tmpl" {{ FLAGS }}
    fi

# Show where an upgrade stands (branch, base, commits, unresolved suggestions).
forge-upgrade-status:
    #!/usr/bin/env bash
    set -euo pipefail
    branch=$(git branch --list 'forge/upgrade-*' --format='%(refname:short)' | head -1)
    if [[ -z "$branch" ]]; then
        printf "\033[0;36mno upgrade in progress (no forge/upgrade-* branch); baseline: %s\033[0m\n" \
            "$(sed -n 's/^template-version *= *"\([^"]*\)".*/\1/p' docs/forge/FORGE-STAMP.toml)"
        exit 0
    fi
    base=$(git config --get forge.upgradeBase 2>/dev/null || echo "?")
    printf "\033[0;34mupgrade branch:\033[0m %s (base: %s)\n" "$branch" "$base"
    git log --oneline "${base}..${branch}" 2>/dev/null | sed 's/^/    /' || true
    pending=$(git ls-files --others --exclude-standard --ignored | grep '\.forge-suggested$' || true)
    if [[ -n "$pending" ]]; then
        printf "\033[1;33munresolved suggestions (diff against yours, merge by hand, delete):\033[0m\n%s\n" "$pending" | sed 's/^/    /'
    fi
    printf "\033[0;36m  keep it:  just go, then push the branch and open a PR\033[0m\n"
    printf "\033[0;36m  drop it:  just forge-upgrade-undo\033[0m\n"

# Undo the ENTIRE upgrade: back to the base branch, upgrade branch deleted.
forge-upgrade-undo:
    #!/usr/bin/env bash
    set -euo pipefail
    branch=$(git branch --list 'forge/upgrade-*' --format='%(refname:short)' | head -1)
    [[ -n "$branch" ]] || { printf "\033[1;33mnothing to undo: no forge/upgrade-* branch\033[0m\n"; exit 1; }
    base=$(git config --get forge.upgradeBase 2>/dev/null || echo "")
    [[ -n "$base" ]] || { printf "\033[1;33mno recorded base branch; git switch <branch> and delete %s yourself\033[0m\n" "$branch"; exit 1; }
    if [[ -n "$(git status --porcelain)" ]]; then
        printf "\033[1;33muncommitted changes present; commit or stash them, then re-run\033[0m\n"; exit 1
    fi
    git switch "$base"
    git branch -D "$branch"
    git config --unset forge.upgradeBase 2>/dev/null || true
    find . -name '*.forge-suggested' -not -path './target/*' -delete 2>/dev/null || true
    printf "\033[0;32mdone: back on %s, %s deleted.\033[0m\n" "$base" "$branch"
