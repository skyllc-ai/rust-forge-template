#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# One-time GitHub-side bootstrap for a repo created from rust-forge-template.
#
# A template repository copies FILES only. This script (re)creates the
# server-side state the machinery expects:
#   * labels used by ci-failure-notify / auto-rerun
#   * the dormant-lane repo variables (all "false" - flip via docs/forge/COMPONENTS.md)
#   * branch ruleset for main (required PR + required status checks +
#     MERGE QUEUE - pr-fast.yml already subscribes to merge_group)
#
# NOTE: rulesets (and therefore the merge queue) require a PUBLIC repo or
# GitHub Pro/Team. On a private free-plan repo this section degrades to a
# warning - re-run this script once the repo goes public.
#   * squash-merge + auto-merge repo settings
#
# Requires: gh CLI authenticated with admin on the repo.
# Idempotent: safe to re-run.

set -euo pipefail

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "🔧 Bootstrapping GitHub-side state for ${REPO}"

# ── 1. Labels (tiered CI-failure triage) ─────────────────────────────
echo "── labels"
for spec in \
  "ci-failure-tier-1|D93F0B|Tier-1 (required PR gate) failure" \
  "ci-failure-tier-2|E99695|Tier-2 (nightly suite) failure" \
  "ci-failure-release|B60205|Release pipeline failure" \
  "preview-artifacts|0E8A16|Build preview artifacts for this PR (lane:preview)" \
  "preview-macos|0E8A16|Also build the macOS preview artifacts (lane:preview)"; do
  IFS='|' read -r name color desc <<<"${spec}"
  gh label create "${name}" --color "${color}" --description "${desc}" --force >/dev/null
  echo "   ✅ ${name}"
done

# ── 1b. Attribution topic: the public credit for the scaffolding.
#        Visible on the repo homepage; remove it if you prefer not to
#        credit the template (the machinery does not depend on it).
echo "── attribution topic"
if gh repo edit "${REPO}" --add-topic rust-forge-template >/dev/null 2>&1; then
  echo "   ✅ topic rust-forge-template (public credit - remove any time)"
else
  echo "   ⚠  could not add topic (add manually: gh repo edit --add-topic rust-forge-template)"
fi

# ── 2. Dormant-lane repo variables (all off; see docs/forge/COMPONENTS.md) ──────
echo "── lane variables (all false - activation is a conscious flip)"
for lane in LANE_RELEASE LANE_RELEASE_PLZ LANE_CRATES LANE_WINGET LANE_CODECOV LANE_CODEQL LANE_SLSA; do
  gh variable set "${lane}" --body "false"
  echo "   ✅ ${lane}=false"
done

# ── 3. Repo merge settings ───────────────────────────────────────────
echo "── merge settings (squash-only + auto-merge + delete-branch-on-merge)"
gh repo edit \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --enable-auto-merge \
  --delete-branch-on-merge >/dev/null
echo "   ✅ done"

# ── 4. Branch ruleset for main ───────────────────────────────────────
# The ruleset is DATA: `scripts/ci/main-ruleset.json` (deletion,
# force-push and linear-history protection, required signatures, a PR
# with every thread resolved, the two required checks whose literal
# names the workflow-drift gate pins, and the merge queue).
# `apply_main_ruleset.sh` creates it the first time and updates it in
# place afterwards, so re-running this script converges the live
# ruleset on the file instead of skipping it. `just protect-main` is
# the same call for a later re-apply.
#
# Pass `--without-signatures` here until `just doctor-signing` is green
# for every committer (ADOPTING.md step 5): the signature rule blocks
# every unsigned merge the moment it is active.
echo "── ruleset: main-protection"
if bash "$(dirname "$0")/apply_main_ruleset.sh" "${REPO}" ${RULESET_FLAGS:-} 2>/dev/null; then
  echo "   ✅ applied from scripts/ci/main-ruleset.json"
else
  echo "   ⚠  could not apply the ruleset (private repos need GitHub Pro/Team or a public repo)"
  echo "      → re-run this script after making the repo public or upgrading the plan;"
  echo "        until then the pre-push hook refuses main pushes locally and"
  echo "        main-merge-guard.yml reverts unverified merges server-side"
fi

echo "── ruleset: tag-protection-v-prefix"
TAG_RULESET_JSON=$(cat <<'JSON'
{
  "name": "tag-protection-v-prefix",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON
)
if gh api "repos/${REPO}/rulesets" --jq '.[].name' 2>/dev/null | grep -qx "tag-protection-v-prefix"; then
  echo "   ↷ already exists - skipping"
elif echo "${TAG_RULESET_JSON}" | gh api -X POST "repos/${REPO}/rulesets" --input - >/dev/null 2>&1; then
  echo "   ✅ created"
else
  echo "   ⚠  could not create ruleset (private repos need GitHub Pro/Team or a public repo)"
fi

# ── 6. Manual steps gh cannot do ─────────────────────────────────────
cat <<'EOF'

📋 Manual follow-ups (GitHub UI / conscious decisions):
   1. Signed commits: add a "required signatures" rule to main-protection
      once every committer has a signing key (`just doctor-signing`).
   2. Secrets (only when the matching lane goes live):
      CODECOV_TOKEN (lane:codecov), CARGO_REGISTRY_TOKEN (lane:crates-publish),
      WINGET_TOKEN (lane:winget).
   3. Dependabot: Settings → Code security - enable Dependabot alerts +
      security updates (dependabot.yml in-repo handles version updates).
   4. Mark the TEMPLATE repo (not this one) as "Template repository" if you
      have not already.
EOF

echo
echo "🎉 bootstrap complete"
