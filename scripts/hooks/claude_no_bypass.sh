#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# Claude Code PreToolUse guard: reject any Bash tool call that bypasses the
# repo's quality gates.
#
# Blocked patterns:
#   * `--no-verify`        — skips the pre-commit / pre-push hooks entirely
#   * `-c core.hooksPath=` — inline override that silently disables the
#                            tracked hooks in scripts/hooks/
#
# Why this exists: the gates (fmt, typos, file-size, clippy, deny, ...) are
# the repo's contract.  A whole branch was once committed with --no-verify
# "for fast iteration" and the accumulated drift (25 files of rustfmt rot,
# typos, file-size violations) only surfaced at merge time.  Fix the failing
# gate at its root instead of skipping it.
#
# Wired up in .claude/settings.json (PreToolUse, matcher "Bash").  Exit code
# 2 blocks the tool call and feeds stderr back to the agent.

set -euo pipefail

payload="$(cat)"

command="$(printf '%s' "$payload" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
')"

# Match only actual invocations: `git ... --no-verify` / `git -c core.hooksPath`
# on one line, or a continuation line starting with the flag.  Plain prose
# mentions of the flag (PR bodies, docs) must not trip the guard.
if printf '%s' "$command" | grep -qE -- 'git[^|;&]*--no-verify|git[^|;&]*-c[[:space:]]*core\.hooksPath|^[[:space:]]*--no-verify'; then
  {
    echo "BLOCKED: gate-bypass flag detected (--no-verify or core.hooksPath override)."
    echo "The quality gates in scripts/hooks/ must run on every commit and push."
    echo "Fix the failing gate at its root cause instead of bypassing it."
  } >&2
  exit 2
fi

exit 0
