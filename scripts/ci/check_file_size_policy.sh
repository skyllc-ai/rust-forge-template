#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.

set -euo pipefail

exception_file="scripts/ci/file_size_exceptions.txt"
oversized_file="$(mktemp)"
trap 'rm -f "$oversized_file"' EXIT

if [[ ! -f "$exception_file" ]]; then
  printf 'ERROR: exception file not found: %s\n' "$exception_file" >&2
  exit 1
fi

find crates/ -name '*.rs' -exec wc -l {} \; \
  | awk '$1 > 800 { print $2 "|" $1 }' \
  | sort > "$oversized_file"

status=0

while IFS='|' read -r path lines; do
  [[ -n "$path" ]] || continue

  if ! grep -Fq "${path}|" "$exception_file"; then
    printf 'MISSING_EXCEPTION: %s (%s LOC)\n' "$path" "$lines"
    status=1
    continue
  fi

  if ! sed -n '1,60p' "$path" | grep -Eq '^//! Exception:'; then
    printf 'MISSING_COMMENT: %s (%s LOC)\n' "$path" "$lines"
    status=1
  fi
done < "$oversized_file"

while IFS='|' read -r path reason; do
  [[ -n "$path" && "${path:0:1}" != "#" ]] || continue

  if ! grep -Fq "${path}|" "$oversized_file"; then
    printf 'STALE_EXCEPTION: %s\n' "$path"
    status=1
  fi

  if [[ -z "$reason" ]]; then
    printf 'MISSING_REASON: %s\n' "$path"
    status=1
  fi
done < "$exception_file"

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

printf 'File size policy OK:\n'
while IFS='|' read -r path lines; do
  [[ -n "$path" ]] || continue
  reason=$(grep -F "${path}|" "$exception_file" | head -n 1 | cut -d'|' -f2-)
  printf 'ALLOW: %s (%s LOC) -- %s\n' "$path" "$lines" "$reason"
done < "$oversized_file"