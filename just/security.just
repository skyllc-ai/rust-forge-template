# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# Supply-chain / cargo-vet maintenance recipes.
#
# These recipes wrap the four-layer cargo-vet audit-discipline policy
# documented in `docs/architecture/security/supply-chain-posture.md`
# §"Mandating audits over blanket bumps".
#
#   Layer 1 - `just vet-discipline`        (the CI gate, locally invokable)
#   Layer 2 - `just vet-bump <crate>`      (the guided audit driver)
#   Layer 3 - CODEOWNERS line on supply-chain/  (no recipe)
#   Layer 4 - `Vet-Reviewed-Diff:` commit trailer (enforced by Layer 1)

# Run the cargo-vet audit-discipline gate locally against
# origin/main..HEAD (the same range the pre-push hook and pr-fast CI
# job check).  Useful for verifying a `vet-bump` workflow before push.
vet-discipline:
    bash scripts/ci/check_vet_audit_discipline.sh range origin/main..HEAD

# Run the "Bugs Rust Won't Catch" anti-pattern regression gate
# (scripts/ci/anti_pattern_gate.sh).  Fails if any forbidden anti-pattern
# (silent lossy UTF decode, predictable temp, perms-after-create on
# secrets, raw key write, discarded control writes) is reintroduced into
# production code.  Deliberate exceptions carry an inline
# `// AUDIT-OK(<category>): <reason>` marker.  Wired into the `go` lane.
audit-gate:
    bash scripts/ci/anti_pattern_gate.sh

# Guided cargo-vet exemption bump - prints a step-by-step recipe to
# replace a "lazy" exemption version bump (the PR #166 anti-pattern)
# with a proper delta audit anchored on the existing exemption.
#
# Usage:
#   just vet-bump <crate>                       # auto-detect OLD + NEW
#   just vet-bump <crate> <new-version>         # auto-detect OLD
#   just vet-bump <crate> <old-ver> <new-ver>   # both explicit
vet-bump CRATE NEW="" OLD="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{OLD}}" && -n "{{NEW}}" ]]; then
        bash scripts/ci/vet_bump.sh "{{CRATE}}" "{{OLD}}" "{{NEW}}"
    elif [[ -n "{{NEW}}" ]]; then
        bash scripts/ci/vet_bump.sh "{{CRATE}}" "{{NEW}}"
    else
        bash scripts/ci/vet_bump.sh "{{CRATE}}"
    fi
