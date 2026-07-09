#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# `just vet-bump` driver — guided cargo-vet exemption bump with audit
# and trailer hygiene.
#
# **Why this exists** — the lazy fix for "tokio 1.52.2 -> 1.52.3 broke
# `cargo vet check`" is to bump `[[exemptions.tokio]] version = "..."`
# and call it a day.  That turns every exemption into a permanent
# rubber stamp.  The discipline gate in
# `scripts/ci/check_vet_audit_discipline.sh` blocks this pattern at
# pre-push and PR-CI; this script is the easy-button replacement.
#
# **Workflow** (mirrors PR #170's manual recipe):
#
#   1. Locate the current exemption's version (OLD).
#   2. Locate the version cargo.lock now wants (NEW).
#   3. Print the commands the operator should run to:
#        a. `cargo vet diff <crate> OLD NEW` — review the upstream diff.
#        b. `cargo vet certify <crate> OLD NEW` — record the audit
#           (interactive: prompts for criteria + notes).
#        c. (No exemption bump needed — the delta audit anchored on OLD
#           extends the trust chain forward to NEW.)
#        d. Stage `supply-chain/audits.toml`, commit with a
#           `Vet-Reviewed-Diff: <crate>@OLD->NEW` trailer.
#
# **Modes**:
#
#   just vet-bump <crate>             -- auto-detect OLD from
#                                        supply-chain/config.toml and
#                                        NEW from Cargo.lock.
#   just vet-bump <crate> <new>       -- explicit NEW (e.g. for a
#                                        bump that is not yet in
#                                        Cargo.lock).
#   just vet-bump <crate> <old> <new> -- both explicit (no auto-detect).
#
# **Exit codes**:
#   0  printed the guided recipe successfully
#   1  no exemption for crate / no bump needed / argument error

set -euo pipefail

# ── Repo paths ──────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_REL="supply-chain/config.toml"
LOCKFILE_REL="Cargo.lock"

# ── Colours ─────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_CYAN=''
    C_BLUE=''
    C_RESET=''
fi

usage() {
    cat <<USAGE >&2
Usage: $(basename "$0") <crate> [<new-version> | <old-version> <new-version>]

Examples:
  $(basename "$0") tokio                        # auto-detect OLD + NEW
  $(basename "$0") tokio 1.52.3                 # auto-detect OLD, NEW=1.52.3
  $(basename "$0") tokio 1.52.2 1.52.3          # both explicit

The script prints a step-by-step audit recipe; it does NOT mutate any
file or run cargo subcommands.  Run the printed commands in order.
USAGE
    exit 1
}

[[ $# -ge 1 ]] || usage
CRATE="$1"
shift

# ── Pre-flight checks ───────────────────────────────────────────────
if [[ ! -f "$REPO_ROOT/$CONFIG_REL" ]]; then
    printf '%s[FAIL]%s %s not found — run from a ACMEX workspace root\n' \
        "$C_RED" "$C_RESET" "$CONFIG_REL" >&2
    exit 1
fi

if ! command -v cargo-vet >/dev/null 2>&1; then
    printf '%s[FAIL]%s cargo-vet not found on PATH\n' "$C_RED" "$C_RESET" >&2
    printf '   %sInstall: %scargo install cargo-vet --locked%s\n' \
        "$C_YELLOW" "$C_CYAN" "$C_RESET" >&2
    exit 1
fi

# ── Resolve OLD: first exemption version for CRATE in config.toml ──
#
# Note: a crate may appear under multiple `[[exemptions.<crate>]]`
# blocks at different versions (the canonical `crypto-common` case).
# We take the first match here for simplicity; if the operator needs
# to bump a non-first version they can pass OLD explicitly.
old_from_config() {
    awk -v want="$1" '
        function flush() {
            if (!done && crate == want && version != "") {
                print version; done=1; exit
            }
            crate=""; version=""
        }
        /^\[\[exemptions\.[^]]+\]\]$/ {
            flush()
            crate = $0
            sub(/^\[\[exemptions\./, "", crate)
            sub(/\]\]$/, "", crate)
            next
        }
        /^\[/ { flush(); next }
        crate == "" { next }
        /^version[[:space:]]*=[[:space:]]*"/ {
            v = $0
            sub(/^version[[:space:]]*=[[:space:]]*"/, "", v)
            sub(/"[[:space:]]*$/, "", v)
            version = v
        }
        END { if (!done) flush() }
    ' "$REPO_ROOT/$CONFIG_REL"
}

# ── Resolve NEW: distinct package versions for CRATE in Cargo.lock ─
#
# Multiple versions may coexist (semver-incompatible major bumps in
# the dep tree); we emit every distinct version, newline-separated,
# in declaration order.
new_from_lock() {
    awk -v want="$1" '
        BEGIN { in_pkg=0 }
        /^\[\[package\]\]/ { in_pkg=1; pkg=""; ver=""; next }
        /^\[/             { in_pkg=0; next }
        in_pkg && /^name[[:space:]]*=[[:space:]]*"/ {
            n = $0; sub(/^name[[:space:]]*=[[:space:]]*"/, "", n); sub(/"$/, "", n); pkg=n
        }
        in_pkg && /^version[[:space:]]*=[[:space:]]*"/ {
            v = $0; sub(/^version[[:space:]]*=[[:space:]]*"/, "", v); sub(/"$/, "", v); ver=v
            if (pkg == want) { print ver }
        }
    ' "$REPO_ROOT/$LOCKFILE_REL"
}

# ── Argument resolution ────────────────────────────────────────────
case $# in
    0)
        OLD="$(old_from_config "$CRATE")" || true
        if [[ -z "$OLD" ]]; then
            printf '%s[FAIL]%s no exemption for %s%s%s in %s%s%s\n' \
                "$C_RED" "$C_RESET" \
                "$C_CYAN" "$CRATE" "$C_RESET" \
                "$C_CYAN" "$CONFIG_REL" "$C_RESET" >&2
            printf '   This recipe is for bumping an existing exemption.  Add the\n' >&2
            printf '   exemption first (or use %scargo vet regenerate exemptions%s)\n' \
                "$C_CYAN" "$C_RESET" >&2
            exit 1
        fi
        # Pick the first distinct NEW from Cargo.lock that differs from OLD.
        NEW=""
        while IFS= read -r v; do
            if [[ -n "$v" && "$v" != "$OLD" ]]; then
                NEW="$v"
                break
            fi
        done < <(new_from_lock "$CRATE")
        ;;
    1)
        OLD="$(old_from_config "$CRATE")" || true
        NEW="$1"
        if [[ -z "$OLD" ]]; then
            printf '%s[FAIL]%s no exemption for %s in %s — pass OLD explicitly\n' \
                "$C_RED" "$C_RESET" "$CRATE" "$CONFIG_REL" >&2
            exit 1
        fi
        ;;
    2)
        OLD="$1"
        NEW="$2"
        ;;
    *)
        usage
        ;;
esac

if [[ -z "${NEW:-}" ]]; then
    printf '%s[FAIL]%s could not infer NEW version from Cargo.lock for %s\n' \
        "$C_RED" "$C_RESET" "$CRATE" >&2
    printf '   Pass it explicitly: %sjust vet-bump %s <new-version>%s\n' \
        "$C_CYAN" "$CRATE" "$C_RESET" >&2
    exit 1
fi

if [[ "$OLD" == "$NEW" ]]; then
    printf '%s[OK]%s exemption for %s already at %s — nothing to bump\n' \
        "$C_GREEN" "$C_RESET" "$CRATE" "$OLD"
    exit 0
fi

# Detect direction (informational only; the discipline gate is
# direction-insensitive — see `check_vet_audit_discipline.sh`).
if [[ "$OLD" < "$NEW" ]]; then
    DIRECTION="forward"
else
    DIRECTION="backward (anchor restoration)"
fi

# ── Resolve criteria from the existing exemption (so the certify
# call uses the right safe-to-* level by default).  Tolerates missing
# criteria with `safe-to-deploy` fallback (the audited-tree default).
criteria_from_config() {
    awk -v want="$1" '
        function flush() {
            if (!done && crate == want && version != "") {
                print (criteria != "" ? criteria : "safe-to-deploy")
                done=1; exit
            }
            crate=""; version=""; criteria=""
        }
        /^\[\[exemptions\.[^]]+\]\]$/ {
            flush()
            crate = $0
            sub(/^\[\[exemptions\./, "", crate)
            sub(/\]\]$/, "", crate)
            next
        }
        /^\[/ { flush(); next }
        crate == "" { next }
        /^version[[:space:]]*=[[:space:]]*"/ {
            v = $0; sub(/^version[[:space:]]*=[[:space:]]*"/, "", v); sub(/"[[:space:]]*$/, "", v); version = v
        }
        /^criteria[[:space:]]*=[[:space:]]*"/ {
            c = $0; sub(/^criteria[[:space:]]*=[[:space:]]*"/, "", c); sub(/"[[:space:]]*$/, "", c); criteria = c
        }
        END { if (!done) flush() }
    ' "$REPO_ROOT/$CONFIG_REL"
}
CRITERIA="$(criteria_from_config "$CRATE")"
[[ -z "$CRITERIA" ]] && CRITERIA="safe-to-deploy"

# ── Print the guided recipe ─────────────────────────────────────────
cat <<RECIPE

${C_BLUE}# vet-bump:${C_RESET} ${C_CYAN}${CRATE}${C_RESET} ${C_YELLOW}${OLD}${C_RESET} -> ${C_GREEN}${NEW}${C_RESET}  (${DIRECTION}, criteria=${C_CYAN}${CRITERIA}${C_RESET})

${C_YELLOW}Step 1 — review the upstream diff${C_RESET}
${C_CYAN}    cargo vet diff ${CRATE} ${OLD} ${NEW}${C_RESET}

  Read every changed file.  Note anything new under one of:
    · unsafe blocks                    · new \`extern "C"\` symbols
    · network / FS / process I/O       · build.rs side effects
    · feature gates                    · public-API signature drift

${C_YELLOW}Step 2 — record the audit${C_RESET}
${C_CYAN}    cargo vet certify ${CRATE} ${OLD} ${NEW} --criteria ${CRITERIA}${C_RESET}

  cargo-vet will open an editor for the audit notes.  Write a concrete
  summary of WHAT changed (referencing PR numbers / commits / files
  where possible) and WHY it is safe at the chosen criteria level.
  The notes survive in supply-chain/audits.toml and are the audit
  trail downstream consumers will read.

${C_YELLOW}Step 3 — commit the audit${C_RESET}
${C_CYAN}    git add supply-chain/audits.toml${C_RESET}
${C_CYAN}    git commit -S \\
        -m 'chore(security): audit ${CRATE} ${OLD} -> ${NEW}' \\
        --trailer 'Vet-Reviewed-Diff: ${CRATE}@${OLD}->${NEW}'${C_RESET}

  The ${C_CYAN}Vet-Reviewed-Diff:${C_RESET} trailer is mandatory — the discipline
  gate (scripts/ci/check_vet_audit_discipline.sh) checks for it on
  every commit that bumps an exemption.  Branch protection enforces
  signed commits on main (${C_CYAN}-S${C_RESET}).

${C_YELLOW}Step 4 — verify locally${C_RESET}
${C_CYAN}    cargo vet check --locked${C_RESET}
${C_CYAN}    bash scripts/ci/check_vet_audit_discipline.sh range origin/main..HEAD${C_RESET}

  Both must exit 0 before push.  See
  ${C_CYAN}docs/architecture/security/supply-chain-posture.md${C_RESET}
  § "Mandating audits over blanket bumps" for the full posture.

RECIPE
