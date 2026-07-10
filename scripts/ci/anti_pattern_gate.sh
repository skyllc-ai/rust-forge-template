#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.
#
# anti_pattern_gate.sh - regression guard for the "Bugs Rust Won't Catch"
# audit (docs/architecture/code-quality/bugs-rust-wont-catch-audit.md).
#
# Fails (exit 1) if any forbidden anti-pattern is reintroduced into
# production code under `crates/**/src/**` (test files excluded). This
# is what keeps the WI-* mitigations at 100% - a fresh `from_utf16_lossy`
# in a parser, a predictable `File::create` temp, or a `set_permissions`
# on a secret will be blocked at the gate.
#
# Escape hatch: a deliberate, justified exception is allowed when the
# offending line OR the line immediately above carries an explicit
#   // AUDIT-OK(<category>): <reason>
# marker. This keeps every exception visible and greppable.
#
# Categories: bytes | tmp | perms | key | errors | path

set -euo pipefail

# Each rule: a label, an extended-regex pattern, and the source scope.
# A match is a violation UNLESS the matched line or the line above it
# carries an `// AUDIT-OK(...)` marker.

status=0

# Report a violation and flip the exit status.
report() {
  printf '❌ %s\n   %s\n' "$1" "$2"
  status=1
}

# Returns 0 (allowed) if `file:line` carries an AUDIT-OK marker on the
# matched line or the line directly above it.
has_audit_ok() {
  local file="$1" lineno="$2"
  # Matched line itself.
  if sed -n "${lineno}p" "$file" | grep -Eq '// *AUDIT-OK\('; then
    return 0
  fi
  # Walk upward through the CONTIGUOUS `//` comment block directly above
  # the match. This lets a multi-line justification carry the
  # `AUDIT-OK(<category>): <reason>` marker on any of its lines (commonly
  # the first), not only the single line immediately above the code.
  local probe=$(( lineno - 1 ))
  while (( probe >= 1 )); do
    local line
    line="$(sed -n "${probe}p" "$file")"
    # Stop at the first non-comment, non-blank line (end of the block).
    if ! printf '%s\n' "$line" | grep -Eq '^[[:space:]]*//'; then
      break
    fi
    if printf '%s\n' "$line" | grep -Eq '// *AUDIT-OK\('; then
      return 0
    fi
    probe=$(( probe - 1 ))
  done
  return 1
}

# Run one rule across a file set. $1=label $2=regex; remaining args=files.
run_rule() {
  local label="$1" pattern="$2"
  shift 2
  local file lineno content
  while IFS=: read -r file lineno content; do
    [[ -n "$file" ]] || continue
    # Skip matches inside line/doc comments: a `//` or `///` line cannot
    # itself BE a lossy conversion / anti-pattern - it only mentions the
    # token (e.g. doc comments on the approved decoder). Anti-patterns are
    # about executable code, not prose.
    if printf '%s\n' "$content" | grep -Eq '^[[:space:]]*//'; then
      continue
    fi
    if has_audit_ok "$file" "$lineno"; then
      continue
    fi
    report "$label" "$file:$lineno: ${content#"${content%%[![:space:]]*}"}"
  done < <(grep -REn "$pattern" "$@" 2>/dev/null || true)
}

# Source scope: all crate src dirs, excluding any path containing `test`
# (test modules + integration tests are exempt - the anti-patterns are
# about PROD code).
mapfile -t SRC_FILES < <(
  find crates -type f -name '*.rs' \
    -not -path '*test*' \
    -not -path '*/benches/*' \
    -not -path '*/fuzz/*' \
    | sort
)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  printf 'ERROR: no source files found under crates/**/src\n' >&2
  exit 1
fi

# ── Category 4 (bytes): lossy UTF conversions must route through the
#    instrumented decoder (WI-4.1) or be AUDIT-OK(bytes) display-only. ──
run_rule "bytes: from_utf16_lossy (use decode_name_utf16le / AUDIT-OK)" \
  'from_utf16_lossy' "${SRC_FILES[@]}"
run_rule "bytes: from_utf8_lossy feeding a decision (strict-parse or AUDIT-OK)" \
  'from_utf8_lossy' "${SRC_FILES[@]}"

# ── Category 1/2 (tmp): predictable temp name (WI-2.4/1.2). ──
run_rule "tmp: predictable .acmex.tmp temp (use randomised create_new_secure_file)" \
  '\.with_extension\("acmex\.tmp"\)' "${SRC_FILES[@]}"

# ── Category 2 (perms): perms-after-create on secrets. The legacy
#    set_file_permissions_owner_only helper is the one allowed home for
#    set_permissions; flag any OTHER set_permissions in acmex-security. ──
while IFS=: read -r file lineno content; do
  [[ -n "$file" ]] || continue
  # Allow it inside the documented legacy compat helper.
  if grep -Eq 'fn set_file_permissions_owner_only' "$file" \
     && sed -n "$(( lineno > 12 ? lineno - 12 : 1 )),${lineno}p" "$file" \
        | grep -Eq 'fn set_file_permissions_owner_only'; then
    continue
  fi
  if has_audit_ok "$file" "$lineno"; then continue; fi
  report "perms: set_permissions in acmex-security (born-perms or AUDIT-OK)" \
    "$file:$lineno: ${content#"${content%%[![:space:]]*}"}"
done < <(grep -REn 'set_permissions\(' crates/acmex-security/src 2>/dev/null || true)

# ── Category 2 (key): raw write of key material in keystore. ──
run_rule "key: std::fs::write in keystore.rs (use write_secret_file)" \
  'std::fs::write\(' crates/acmex-security/src/keystore.rs

# ── Category 6 (errors): discarded control-channel writes. ──
run_rule "errors: discarded stream/pipe write/flush (propagate/log or AUDIT-OK)" \
  'drop\((stream|pipe)\.(write_all|flush)' "${SRC_FILES[@]}"

if [[ $status -eq 0 ]]; then
  printf '✅ anti-pattern gate: no forbidden patterns in production code\n'
fi
exit "$status"
