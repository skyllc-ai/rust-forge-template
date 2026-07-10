#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# forge-stamp drift gate: docs/forge/TEMPLATE_VERSION and the
# template-version field in docs/forge/FORGE-STAMP.toml are two records of
# the same fact (the template baseline). In forged repos both are frozen
# birth-certificates and this always passes; in the template itself it
# fires when a baseline bump moves one file without the other.
set -euo pipefail
VF="docs/forge/TEMPLATE_VERSION"
SF="docs/forge/FORGE-STAMP.toml"
[[ -f "$VF" && -f "$SF" ]] || { echo "forge-stamp: OK (files absent; nothing to compare)"; exit 0; }
v_file="$(tr -d '[:space:]' < "$VF")"
v_stamp="$(sed -n 's/^template-version *= *"\([^"]*\)".*/\1/p' "$SF" | head -1)"
if [[ "$v_file" == "$v_stamp" && -n "$v_file" ]]; then
    echo "forge-stamp: OK (baseline $v_file)"
else
    echo "forge-stamp: DRIFT - $VF says '$v_file' but $SF says '$v_stamp'." >&2
    echo "A baseline bump must move both files in the same commit." >&2
    exit 1
fi
