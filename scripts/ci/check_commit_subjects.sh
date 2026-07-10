#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# Conventional Commits subject validator.
#
# **Why this exists** - `.github/workflows/commitlint.yml` validates the
# **PR title** at PR-open / synchronize time.  That catch is post-push:
# the contributor finds out about a malformed scope like
# `feat(acmex-core, daemon)` only after the workflow has already failed
# upstream.  This script encodes the SAME regex as the CI workflow
# (single source of truth - see "REGEX" below) so the pre-push hook
# (`scripts/hooks/_lint_pre_push.sh`) and the commit-msg hook
# (`scripts/hooks/commit-msg`) can fail the offending subject locally.
#
# **Regex**: mirrors `.github/workflows/commitlint.yml` line 124.
# Updates to either MUST land in the same commit; the
# `commitlint.yml` block has a pointer back to this file so reviewers
# notice the drift.
#
# **Modes**:
#   range RANGE              -- validate every non-merge commit subject
#                              in the git revision range RANGE (e.g.
#                              `origin/main..HEAD` or
#                              `BASE_OID..LOCAL_OID`).  Empty / merges-
#                              only ranges silently succeed.
#   file PATH                -- validate the first non-comment, non-blank
#                              line of PATH (the format `git commit`
#                              passes to `commit-msg` hooks).
#   subject "<subject line>" -- validate a single literal subject string.
#                              Useful for ad-hoc shell checks and tests.
#
# **Exit codes**: 0 conformant, 1 non-conformant (or input error).
#
# **Environment knobs** (all optional):
#   COMMIT_SUBJECT_BYPASS=1  -- emits a warning and exits 0.  Same posture
#                              as `git push --no-verify` for the pre-push
#                              gate -- lets you intentionally land a
#                              non-CC subject (e.g. an emergency hotfix
#                              with a triage prefix the regex doesn't
#                              cover).  Logged so the bypass is visible.
#
# **Allowed types** (mirrors `.github/workflows/commitlint.yml` and
# `docs/CONTRIBUTING.md` -> "Commit message conventions"): feat, fix, perf,
# refactor, docs, test, build, ci, chore, style, revert.
#
# **Scope grammar**: `[a-z0-9-]+`.  Single token -- no spaces, no
# commas, no slashes.  Use a single canonical scope per commit
# (e.g. `feat(daemon)` rather than `feat(acmex-core, daemon)`); cross-
# crate work goes in the body.
#
# **Breaking-change marker**: an optional `!` between the scope and
# the colon (`feat(api)!: drop deprecated --q shorthand`).

set -euo pipefail

# ── Single source of truth for the Conventional Commits regex ───────
# Synchronised with `.github/workflows/commitlint.yml` line 124 and
# `cliff.toml` commit_parsers.  Update all three together or
# release-plz / git-cliff / commitlint will drift.
readonly REGEX='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9-]+\))?!?: .{1,}$'

# ── Colours ─────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'
    C_RESET=$'\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_YELLOW=''
    C_CYAN=''
    C_RESET=''
fi

usage() {
    cat <<USAGE >&2
Usage: $(basename "$0") <mode> <arg>

Modes:
  range RANGE        Validate non-merge commit subjects in RANGE
                     (e.g. 'origin/main..HEAD').
  file PATH          Validate the first non-comment line of PATH
                     (the commit-msg hook input format).
  subject "TEXT"     Validate a single literal subject string.

Examples:
  $(basename "$0") range origin/main..HEAD
  $(basename "$0") file .git/COMMIT_EDITMSG
  $(basename "$0") subject 'feat(daemon): add background USN refresh'
USAGE
    exit 2
}

# ── Bypass guard ───────────────────────────────────────────────────
if [[ "${COMMIT_SUBJECT_BYPASS:-0}" == "1" ]]; then
    printf '%s[WARN]%s commit-subject validator bypassed via COMMIT_SUBJECT_BYPASS=1\n' \
        "$C_YELLOW" "$C_RESET" >&2
    exit 0
fi

# ── Helper: validate one literal subject ───────────────────────────
# Prints the failing subject + a hint when non-conformant; returns
# the appropriate exit code.  Caller aggregates failures across a
# batch.
validate_one() {
    local subject="$1"
    local oid="${2:-}"
    if [[ -z "$subject" ]]; then
        printf '%s[FAIL]%s empty subject%s\n' "$C_RED" "$C_RESET" \
            "${oid:+ (commit ${oid:0:10})}" >&2
        return 1
    fi
    if [[ "$subject" =~ $REGEX ]]; then
        return 0
    fi
    printf '%s[FAIL]%s non-conventional commit subject%s\n' \
        "$C_RED" "$C_RESET" "${oid:+ (commit ${oid:0:10})}" >&2
    printf '   %ssubject:%s %s\n' "$C_CYAN" "$C_RESET" "$subject" >&2
    return 1
}

print_help_block() {
    cat >&2 <<HELP
${C_YELLOW}-> Expected:${C_RESET} ${C_CYAN}type(scope): subject${C_RESET}
   where ${C_CYAN}type${C_RESET} is one of: feat, fix, perf, refactor, docs,
   test, build, ci, chore, style, revert; and ${C_CYAN}scope${C_RESET} is a
   SINGLE [a-z0-9-]+ token (e.g. ${C_CYAN}daemon${C_RESET},
   ${C_CYAN}acmex-core${C_RESET}, ${C_CYAN}daemon/lifecycle${C_RESET} --
   no commas, no spaces).

${C_YELLOW}Examples${C_RESET} (recent ACMEX merges):
   ${C_GREEN}feat(daemon): per-shard USN journal loops replace global 5-min tick${C_RESET}
   ${C_GREEN}refactor(memory-tiering): unify shard-demote events${C_RESET}
   ${C_GREEN}fix(daemon/lifecycle): disarm load-stall force-retire after loading${C_RESET}
   ${C_GREEN}feat(cli)!: drop deprecated --q shorthand${C_RESET}  (the trailing ${C_CYAN}!${C_RESET} marks a breaking change)

${C_YELLOW}Fix${C_RESET}: amend the offending commit's subject:
   ${C_CYAN}git rebase -i <base>${C_RESET}      -> mark the offending commit ${C_CYAN}reword${C_RESET}
   ${C_CYAN}git commit --amend${C_RESET}        -> if it's the most recent

${C_YELLOW}Bypass once${C_RESET} (use sparingly):
   ${C_CYAN}COMMIT_SUBJECT_BYPASS=1 git push${C_RESET}
   ${C_CYAN}git commit --no-verify${C_RESET}    -> skips ALL commit-msg hooks

See ${C_CYAN}docs/CONTRIBUTING.md${C_RESET} -> "Commit message conventions" and
\`.github/workflows/commitlint.yml\` for the canonical reference.
HELP
}

# ── Main ────────────────────────────────────────────────────────────
[[ $# -ge 2 ]] || usage
mode="$1"
arg="$2"
fail=0

case "$mode" in
    range)
        # Walk every non-merge commit in RANGE.  --no-merges drops
        # merge commits (Conventional Commits doesn't apply to merges
        # -- they get auto-generated subjects like "Merge branch ...").
        # An empty range exits 0 silently (e.g. push of branch already
        # at remote-HEAD; the local hook fires anyway and shouldn't
        # bark on a no-op push).
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            printf '%s[FAIL]%s not in a git repository\n' "$C_RED" "$C_RESET" >&2
            exit 1
        fi
        # `git log` with `--format` returns OID<tab>SUBJECT one per
        # line.  We pipe to a `while` so each commit is checked
        # independently.  Process-substitution avoids the subshell
        # variable-scope footgun.
        count=0
        while IFS=$'\t' read -r oid subject; do
            count=$((count + 1))
            validate_one "$subject" "$oid" || fail=1
        done < <(git log --no-merges --format='%H%x09%s' "$arg" 2>/dev/null || true)
        if (( fail )); then
            printf '\n' >&2
            print_help_block
            exit 1
        fi
        # Quiet success unless the user explicitly asked for verbosity.
        if [[ "${COMMIT_SUBJECT_VERBOSE:-0}" == "1" ]]; then
            printf '%s[OK]%s %d commit subject(s) in %s pass Conventional Commits\n' \
                "$C_GREEN" "$C_RESET" "$count" "$arg"
        fi
        ;;

    file)
        # `commit-msg` hook input: the first non-blank, non-comment
        # line is the subject.  `git commit` strips comments before
        # finalising the message so we mirror that here.
        if [[ ! -f "$arg" ]]; then
            printf '%s[FAIL]%s file not found: %s\n' "$C_RED" "$C_RESET" "$arg" >&2
            exit 1
        fi
        # `head` would race against an editor still writing; instead
        # we read the whole file (commit messages are tiny) and pull
        # the first qualifying line.  `awk` keeps memory bounded.
        subject=$(awk '!/^#/ && NF { print; exit }' "$arg")
        if [[ -z "$subject" ]]; then
            # Empty commit message -- git aborts the commit anyway, so
            # we exit 0 and let git's own error path surface it.
            exit 0
        fi
        validate_one "$subject" || { print_help_block; exit 1; }
        ;;

    subject)
        validate_one "$arg" || { print_help_block; exit 1; }
        ;;

    *)
        usage
        ;;
esac
