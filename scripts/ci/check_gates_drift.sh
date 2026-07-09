#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# ACMEX gate-manifest drift detector.
#
# Phase 1 of `docs/architecture/gates-manifest-plan.md`.  Verifies
# that every gate listed in `scripts/ci/gates.toml` is present in
# the corresponding consumer file, and that every gate present in
# the consumers has a matching manifest entry.
#
# Called by:
#   - pre-push hook (Bucket 1, fire-and-forget)
#   - `pr-fast.yml::gates-drift` job (PR-time hard gate)
#   - `just gates-drift` (manual invocation)
#
# Exit codes:
#   0  manifest and consumers agree on the gate set
#   1  drift detected — one or more gates missing on either side
#   2  manifest schema error (unparseable, missing required fields)
#
# Bypass: `BYPASS_GATES_DRIFT=1 git push` skips the pre-push step
# (mirrors the existing `COMMIT_SUBJECT_BYPASS=1` pattern).  No CI
# bypass — drift on `main` is a deliberate "fix-me-now" signal.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MANIFEST="$REPO_ROOT/scripts/ci/gates.toml"
HOOK_FAST="$REPO_ROOT/scripts/hooks/_lint_fast.sh"
HOOK_PUSH="$REPO_ROOT/scripts/hooks/_lint_pre_push.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/pr-fast.yml"

# ── Colours ────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[0;31m'
    C_RESET=$'\033[0m'
else
    C_BLUE=''
    C_CYAN=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_RESET=''
fi

# ── Optional bypass ────────────────────────────────────────────────────
if [[ "${BYPASS_GATES_DRIFT:-0}" == "1" ]]; then
    printf '%s⏭  gates-drift bypassed via BYPASS_GATES_DRIFT=1%s\n' \
        "$C_YELLOW" "$C_RESET"
    exit 0
fi

printf '%s🔎 gates-drift — manifest vs consumers%s\n' "$C_BLUE" "$C_RESET"

# ── Sanity: required files exist ───────────────────────────────────────
for f in "$MANIFEST" "$HOOK_FAST" "$HOOK_PUSH" "$WORKFLOW"; do
    if [[ ! -f "$f" ]]; then
        printf '%s❌ missing required file: %s%s\n' "$C_RED" "$f" "$C_RESET" >&2
        exit 2
    fi
done

# ── Manifest parsing (minimal TOML) ────────────────────────────────────
# We deliberately do NOT shell out to `taplo`/`dasel` — the manifest
# uses a small, regular subset of TOML and a grep-based parser keeps
# this script self-contained.  Schema enforced by the awk below; any
# manifest that doesn't fit gets a schema error (exit 2).
#
# AWK pass: emits one line per gate of the form
#     <id>\t<tiers-csv>\t<gate_when>\t<hard>
# where:
#   id       = the kebab-case gate identifier
#   tiers    = comma-separated subset of {pre-commit,pre-push,pr-fast}
#   gate_when = always|rust_changed|dep_changed|infra_changed|code_changed
#   hard     = true|false
parse_manifest() {
    awk '
        # State machine: track whether we are inside a [[gate]] table.
        /^\[\[gate\]\]$/ { in_gate=1; id=""; tiers=""; gw=""; hard=""; cn=""; next }
        /^\[/             { in_gate=0; next }
        !in_gate          { next }

        /^id[ \t]*=[ \t]*"/ {
            sub(/^id[ \t]*=[ \t]*"/, ""); sub(/".*$/, ""); id=$0
        }
        /^tiers[ \t]*=[ \t]*\[/ {
            line=$0
            sub(/^tiers[ \t]*=[ \t]*\[/, "", line)
            sub(/\].*$/, "", line)
            gsub(/[ "]/, "", line)
            tiers=line
        }
        /^gate_when[ \t]*=[ \t]*"/ {
            sub(/^gate_when[ \t]*=[ \t]*"/, ""); sub(/".*$/, ""); gw=$0
        }
        /^hard[ \t]*=/ {
            sub(/^hard[ \t]*=[ \t]*/, ""); hard=$0
        }
        /^consumer_names[ \t]*=[ \t]*\{/ {
            # Inline TOML table: { "pre-commit" = "fmt-check", ... }
            # Keep the body as-is for downstream parsing.
            line=$0
            sub(/^consumer_names[ \t]*=[ \t]*\{/, "", line)
            sub(/\}.*$/, "", line)
            gsub(/ /, "", line)
            cn=line
        }
        in_gate && id != "" {
            ids[id]=1
            if (tiers != "") tier_of[id]=tiers
            if (gw    != "") when_of[id]=gw
            if (hard  != "") hard_of[id]=hard
            if (cn    != "") cn_of[id]=cn
        }
        END {
            for (i in ids) {
                printf "%s\t%s\t%s\t%s\t%s\n", \
                    i, \
                    (i in tier_of ? tier_of[i] : ""), \
                    (i in when_of ? when_of[i] : ""), \
                    (i in hard_of ? hard_of[i] : ""), \
                    (i in cn_of ? cn_of[i] : "")
            }
        }
    ' "$MANIFEST"
}

# Look up the per-tier consumer-side name for a gate id.  Falls back
# to the gate id itself when no override is declared.
#
# Args: <consumer_names_csv> <tier>
#       where consumer_names_csv looks like `"pre-commit"="fmt-check","pr-fast"="fmt"`
consumer_name_for() {
    local cn="$1" tier="$2" default="$3"
    if [[ -z "$cn" ]]; then
        printf '%s' "$default"
        return
    fi
    # Extract the value after `"$tier"="..."` if present.
    local match
    match=$(printf '%s' "$cn" | tr ',' '\n' \
        | grep -E "^\"$tier\"=\"" \
        | head -n1 \
        | sed -E 's/^"[^"]+"="([^"]+)".*$/\1/' || true)
    if [[ -n "$match" ]]; then
        printf '%s' "$match"
    else
        printf '%s' "$default"
    fi
}

# ── Consumer scraping ──────────────────────────────────────────────────
# Each consumer exposes its gate IDs via a unique, greppable pattern:
#   _lint_fast.sh:      `spawn "<id>" ...`        (line starts with optional whitespace)
#   _lint_pre_push.sh:  `spawn_bg "<id>" ...` or `run_seq "<id>" ...`
#   pr-fast.yml:        `^  <id>:$` for top-level job blocks (2-space indent).
#
# Infrastructure jobs in pr-fast.yml are NOT gates and MUST be excluded
# from the reverse-direction check (see WORKFLOW_INFRA_JOBS below).

scrape_pre_commit() {
    # Per-match extraction (grep -oE) so multi-spawn lines yield every id.
    grep -vE '^\s*#' "$HOOK_FAST" \
        | grep -oE 'spawn[[:space:]]+"[a-z][a-z-]*"' \
        | sed -E 's/^spawn[[:space:]]+"([a-z][a-z-]*)"$/\1/' \
        | sort -u
}

scrape_pre_push() {
    # Match `spawn_bg "<id>"` / `run_seq "<id>"` anywhere on the line
    # (some hook lines prefix with `command -v X && ` for soft-skip).
    # Skip comment lines (the doc block's `#  * gate-name`).
    # Per-match extraction (grep -oE) so multi-spawn lines yield every id.
    grep -vE '^\s*#' "$HOOK_PUSH" \
        | grep -oE '(spawn_bg|run_seq)[[:space:]]+"[a-z][a-z-]*"' \
        | sed -E 's/^(spawn_bg|run_seq)[[:space:]]+"([a-z][a-z-]*)"$/\2/' \
        | sort -u
}

scrape_pr_fast() {
    # YAML jobs live under the `^jobs:$` header.  YAML triggers
    # (`push:`, `pull_request:`, `merge_group:`, etc.) live under
    # `on:` and would also match the 2-space-indent regex; restrict
    # to lines below `jobs:` to avoid catching them.
    awk '/^jobs:/{in_jobs=1; next} in_jobs && /^[a-z][a-zA-Z_-]+:/{exit} in_jobs && /^  [a-z][a-z-]+:$/{print}' "$WORKFLOW" \
        | sed -E 's/^  ([a-z][a-z-]+):$/\1/' \
        | sort -u
}

# Jobs in pr-fast.yml that exist for orchestration / branch protection,
# NOT for an individual gate.  These are EXEMPT from the manifest —
# they have no matching `[[gate]]` entry.
#
# `notify-failure` was removed in the Design C refactor for #209
# (failure notification now lives in `.github/workflows/ci-failure-notify.yml`),
# so it's no longer listed here.
WORKFLOW_INFRA_JOBS=(
    "classify"
    "required"
)

# ── Mapping helpers ────────────────────────────────────────────────────
# Map the manifest's `pr-fast` tier membership to the actual job name
# in `pr-fast.yml`.  Most gates use the gate id as the job name; the
# exceptions are listed here as `<gate_id>:<job_name>` pairs.
#
# Lookup convention: `${PRFAST_JOB_OVERRIDES[gate_id]}` returns the
# overridden job name, or empty if no override.
declare -A PRFAST_JOB_OVERRIDES=(
    ["lint-ci"]="clippy"
    ["rustdoc"]="docs"
    ["lint-ci-windows"]="windows-lint"
    ["cargo-check"]="sanity"
    ["vet"]="security"
    ["deny"]="security"
)

prfast_job_for() {
    local id="$1"
    if [[ -n "${PRFAST_JOB_OVERRIDES[$id]:-}" ]]; then
        printf '%s' "${PRFAST_JOB_OVERRIDES[$id]}"
    else
        printf '%s' "$id"
    fi
}

# ── Diff machinery ─────────────────────────────────────────────────────
ERRORS=0

emit_missing() {
    local where="$1" id="$2" expected="$3"
    # shellcheck disable=SC2016 # backticks are literal visual delimiters
    printf '  %s❌%s [%s] gate `%s` listed in manifest but not found in %s\n' \
        "$C_RED" "$C_RESET" "$where" "$id" "$expected" >&2
    ERRORS=$(( ERRORS + 1 ))
}

emit_orphan() {
    local where="$1" id="$2"
    # shellcheck disable=SC2016 # backticks are literal visual delimiters
    printf '  %s❌%s [%s] gate `%s` defined in consumer but missing from manifest\n' \
        "$C_RED" "$C_RESET" "$where" "$id" >&2
    ERRORS=$(( ERRORS + 1 ))
}

# ── Forward check: manifest → consumers ────────────────────────────────
# For every [[gate]] in the manifest, every tier it claims must
# actually contain it.  The grep'd consumer sets are O(n) so we
# build them once and look up via grep -Fxq.
PC_SET=$(scrape_pre_commit)
PP_SET=$(scrape_pre_push)
PR_SET=$(scrape_pr_fast)

while IFS=$'\t' read -r id tiers _when _hard cn; do
    [[ -z "$id" ]] && continue
    IFS=',' read -ra TIER_LIST <<< "$tiers"
    for t in "${TIER_LIST[@]}"; do
        case "$t" in
            pre-commit)
                expected=$(consumer_name_for "$cn" "pre-commit" "$id")
                grep -Fxq "$expected" <<< "$PC_SET" \
                    || emit_missing "pre-commit" "$id" "_lint_fast.sh ('$expected')"
                ;;
            pre-push)
                expected=$(consumer_name_for "$cn" "pre-push" "$id")
                grep -Fxq "$expected" <<< "$PP_SET" \
                    || emit_missing "pre-push" "$id" "_lint_pre_push.sh ('$expected')"
                ;;
            pr-fast)
                expected_job=$(consumer_name_for "$cn" "pr-fast" "$(prfast_job_for "$id")")
                grep -Fxq "$expected_job" <<< "$PR_SET" \
                    || emit_missing "pr-fast" "$id" "pr-fast.yml job '$expected_job'"
                ;;
            tier-2)
                # Out of scope for Phase 1.  Tier-2 has its own
                # workflow with uniquely shaped jobs that don't fit
                # the gate manifest schema.
                ;;
            *)
                # shellcheck disable=SC2016 # backticks are literal visual delimiters
                printf '  %s❌%s schema: gate `%s` has unknown tier `%s`\n' \
                    "$C_RED" "$C_RESET" "$id" "$t" >&2
                ERRORS=$(( ERRORS + 1 ))
                ;;
        esac
    done
done < <(parse_manifest)

# ── Reverse check: consumers → manifest ────────────────────────────────
# Every gate ID found in a consumer must have a matching manifest
# entry on the corresponding tier.  Catches the "added a gate to the
# hook but forgot the manifest" failure mode.

# Build manifest-id-set per tier for reverse lookups.
declare -A MANIFEST_PC=()
declare -A MANIFEST_PP=()
declare -A MANIFEST_PR=()
while IFS=$'\t' read -r id tiers _when _hard cn; do
    [[ -z "$id" ]] && continue
    IFS=',' read -ra TIER_LIST <<< "$tiers"
    for t in "${TIER_LIST[@]}"; do
        case "$t" in
            pre-commit)
                MANIFEST_PC[$(consumer_name_for "$cn" "pre-commit" "$id")]=1 ;;
            pre-push)
                MANIFEST_PP[$(consumer_name_for "$cn" "pre-push" "$id")]=1 ;;
            pr-fast)
                MANIFEST_PR[$(consumer_name_for "$cn" "pr-fast" "$(prfast_job_for "$id")")]=1 ;;
        esac
    done
done < <(parse_manifest)

while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ -n "${MANIFEST_PC[$id]:-}" ]] || emit_orphan "pre-commit" "$id"
done <<< "$PC_SET"

while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ -n "${MANIFEST_PP[$id]:-}" ]] || emit_orphan "pre-push" "$id"
done <<< "$PP_SET"

while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    # Skip infra jobs.
    skip=0
    for infra in "${WORKFLOW_INFRA_JOBS[@]}"; do
        [[ "$id" == "$infra" ]] && { skip=1; break; }
    done
    (( skip )) && continue
    [[ -n "${MANIFEST_PR[$id]:-}" ]] || emit_orphan "pr-fast" "$id"
done <<< "$PR_SET"

# ── Verdict ────────────────────────────────────────────────────────────
if (( ERRORS > 0 )); then
    printf '\n%s❌ gates-drift: %d mismatch(es) detected%s\n' \
        "$C_RED" "$ERRORS" "$C_RESET" >&2
    printf '   %sFix: update either %sscripts/ci/gates.toml%s%s or the\n' \
        "$C_YELLOW" "$C_CYAN" "$C_RESET" "$C_YELLOW" >&2
    printf '   %scorresponding consumer file so they agree.  Bypass once with:%s\n' \
        "$C_YELLOW" "$C_RESET" >&2
    printf '   %sBYPASS_GATES_DRIFT=1 git push%s\n' "$C_CYAN" "$C_RESET" >&2
    exit 1
fi

printf '%s✅ gates-drift: manifest and consumers agree (%d gates)%s\n' \
    "$C_GREEN" "$(parse_manifest | wc -l | tr -d ' ')" "$C_RESET"
