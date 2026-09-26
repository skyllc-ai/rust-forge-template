#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# Applies `scripts/ci/main-ruleset.json` to the repository's default
# branch through the GitHub rulesets API, creating the ruleset the
# first time and updating it in place afterwards (matched by name).
# Idempotent; prints the resulting rules. Needs `gh` logged in with
# admin on the repository, and a plan that offers rulesets on a
# private repository (the free plan answers 403; until then the
# pre-push hook is the local mirror and main-merge-guard.yml the
# server-side backstop).
#
# The JSON file is the single source of truth: `bootstrap-github.sh`
# calls this script for its ruleset step, and `just protect-main` is
# the one-liner for a re-apply after the file changes.
#
# `--without-signatures` drops the `required_signatures` rule from
# what is applied (ADOPTING.md step 5: add it only once
# `just doctor-signing` is green for every committer). Re-run without
# the flag to add it later; the update is in place.
#
# Usage: bash scripts/ci/apply_main_ruleset.sh [owner/repo] [--without-signatures]
set -euo pipefail
repo=""; without_signatures=0
for arg in "$@"; do
    case "$arg" in
        --without-signatures) without_signatures=1 ;;
        --help|-h) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) repo="$arg" ;;
    esac
done
repo="${repo:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
spec="$(dirname "$0")/main-ruleset.json"
[[ -f "$spec" ]] || { echo "missing $spec" >&2; exit 1; }
name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$spec")"
payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
if [[ $without_signatures -eq 1 ]]; then
    python3 - "$spec" > "$payload" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["rules"] = [rule for rule in spec["rules"] if rule["type"] != "required_signatures"]
print(json.dumps(spec, indent=2))
PY
    echo "applying without the required_signatures rule (--without-signatures)"
else
    cp "$spec" "$payload"
fi
existing="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
    echo "updating ruleset '$name' (#$existing) on $repo"
    gh api --method PUT "repos/$repo/rulesets/$existing" --input "$payload" >/dev/null
else
    echo "creating ruleset '$name' on $repo"
    gh api --method POST "repos/$repo/rulesets" --input "$payload" >/dev/null
fi
gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" | while read -r id; do
    gh api "repos/$repo/rulesets/$id" --jq '"enforcement: \(.enforcement)", (.rules[] | "rule: \(.type)")'
done
