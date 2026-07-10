#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# Self-test for claude_no_bypass.sh (the Claude Code PreToolUse guard).
#
# Each case feeds a simulated tool-call payload to the guard and asserts the
# exit code: 2 = blocked (gate-bypass invocation), 0 = allowed.  Prose that
# merely *mentions* a bypass flag (PR bodies, commit messages, docs) must NOT
# trip the guard - only actual git invocations carrying the flag.
#
# Run directly: bash scripts/hooks/test_claude_no_bypass.sh

set -euo pipefail

guard="$(dirname "$0")/claude_no_bypass.sh"
failures=0

check() {
  local want="$1" desc="$2" cmd="$3"
  local got=0
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | bash "$guard" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    printf 'OK   (exit %s) %s\n' "$got" "$desc"
  else
    printf 'FAIL (exit %s, want %s) %s\n' "$got" "$want" "$desc"
    failures=$((failures + 1))
  fi
}

# --- blocked: real bypass invocations -------------------------------------
check 2 "commit with verify skipped"        'git commit --no-verify -m "x"'
check 2 "push with verify skipped"          'git push --no-verify origin main'
check 2 "inline hooksPath override"         'git -c core.hooksPath=/dev/null push'
check 2 "flag on a continuation line"       $'git commit -m "x" \\\n  --no-verify'
check 2 "compound command hides the flag"   'cargo fmt && git commit --no-verify -m "y"'

# --- allowed: normal work + prose mentions ---------------------------------
check 0 "plain commit and push"             'git commit -m "fix" && git push'
check 0 "prose mention in a PR body"        'gh pr create --body "the branch was iterated with --no-verify earlier"'
check 0 "prose mention in echo"             'echo "never use --no-verify here"'
check 0 "unrelated command"                 'cargo nextest run -p acmex-bench'
check 0 "install-hooks recipe is fine"      'just install-hooks'

if [[ "$failures" -gt 0 ]]; then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
printf 'all guard self-tests passed\n'
