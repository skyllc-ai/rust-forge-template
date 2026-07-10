# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.


# Install and configure sccache for distributed compilation caching.
setup-sccache:
    #!/usr/bin/env bash
    printf "\033[0;34m🚀 Setting up sccache for faster compilation...\033[0m\n"
    if ! command -v sccache >/dev/null 2>&1; then printf "\033[0;34m  → Installing sccache...\033[0m\n"; just _install-if-missing sccache sccache; else printf "\033[0;32m  ✅ sccache already installed\033[0m\n"; fi
    SCCACHE_DIR="$HOME/.cache/sccache"
    mkdir -p "$SCCACHE_DIR"
    printf "\033[0;34m  → Cache directory: $SCCACHE_DIR\033[0m\n"
    printf "\033[0;34m  → Setting RUSTC_WRAPPER=sccache\033[0m\n"
    if command -v sccache >/dev/null 2>&1; then printf "\033[0;34m  → Current cache statistics:\033[0m\n"; RUSTC_WRAPPER=sccache sccache --show-stats || true; fi
    printf "\033[0;32m✅ sccache setup complete!\033[0m\n"
    printf "\033[0;34m💡 To enable sccache, set: export RUSTC_WRAPPER=sccache\033[0m\n"
    printf "\033[0;34m💡 Add to your shell profile for permanent activation\033[0m\n"

# Show sccache statistics and performance impact.
sccache-stats:
    #!/usr/bin/env bash
    printf "\033[0;34m📊 sccache compilation cache statistics...\033[0m\n"
    if ! command -v sccache >/dev/null 2>&1; then printf "\033[1;33m⚠️  sccache not installed. Run 'just setup-sccache' first.\033[0m\n"; exit 1; fi
    printf "\033[0;34m  → Cache statistics:\033[0m\n"
    RUSTC_WRAPPER=sccache sccache --show-stats
    printf "\033[0;34m  → Cache location:\033[0m\n"
    printf "    $HOME/.cache/sccache\n"
    if [ -d "$HOME/.cache/sccache" ]; then CACHE_SIZE=$(du -sh "$HOME/.cache/sccache" 2>/dev/null | cut -f1 || echo "unknown"); printf "\033[0;34m  → Cache size: $CACHE_SIZE\033[0m\n"; fi
    printf "\033[0;32m✅ sccache statistics complete!\033[0m\n"

# Clear sccache to free up disk space.
sccache-clear:
    #!/usr/bin/env bash
    printf "\033[0;34m🧹 Clearing sccache compilation cache...\033[0m\n"
    if ! command -v sccache >/dev/null 2>&1; then printf "\033[1;33m⚠️  sccache not installed. Nothing to clear.\033[0m\n"; exit 0; fi
    if [ -d "$HOME/.cache/sccache" ]; then CACHE_SIZE=$(du -sh "$HOME/.cache/sccache" 2>/dev/null | cut -f1 || echo "unknown"); printf "\033[0;34m  → Current cache size: $CACHE_SIZE\033[0m\n"; fi
    RUSTC_WRAPPER=sccache sccache --zero-stats
    rm -rf "$HOME/.cache/sccache"
    mkdir -p "$HOME/.cache/sccache"
    printf "\033[0;32m✅ sccache cache cleared!\033[0m\n"

# Prune the `cargo-llvm-cov` target tree + stale daemon shmem files.
#
# `just test` runs `cargo llvm-cov nextest` which writes an instrumented
# build tree to `$CARGO_TARGET_DIR/llvm-cov-target/`.  That tree can
# grow to 100+ GB over a long session - every profile bump, every
# `.profraw` from a failed run, and every compiled test binary stays
# cached there.  On a near-full disk (Dropbox / external drive / small
# SSD) this is the top cause of ENOSPC that surfaces as:
#
#   handler::csv_blob_tests::try_pack_csv_blob_offloads_large_blob_to_shmem
#     → panicked at 'large multi-column blob must be offloaded to ShmemBlob'
#   handler::paths_blob_tests::try_pack_paths_blob_offloads_large_blob_to_shmem
#     → panicked at 'large path-only projection must be offloaded to ShmemBlob'
#
# The daemon's `write_paths_blob` correctly falls back to
# `SearchPayload::InlineBlob` on disk-full, but those two tests pin
# the shmem branch specifically, so a disk-full environment makes
# them loudly fail - which is exactly the design: silently skipping
# would hide real `write_paths_blob` regressions on healthy hosts.
#
# What it prunes:
#   - `$CARGO_TARGET_DIR/llvm-cov-target/` (instrumented build tree)
#   - `$CARGO_TARGET_DIR/llvm-cov/`        (HTML coverage report)
#   - `$CARGO_TARGET_DIR/**/*.profraw`     (instrumentation output)
#   - `$LOCALAPPDATA/acmex/shmem/`            (Windows)
#     `$XDG_DATA_HOME/acmex/shmem/`           (Linux)
#     `~/Library/Application Support/acmex/shmem/` (macOS)
#
# Safe to re-run; leaves regular `cargo build` artifacts, sccache,
# and the dependency cache untouched.  Reports total freed bytes.

# Prune llvm-cov target tree + orphan daemon shmem files; fixes disk-full ENOSPC failures.
clean-cov:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "\033[0;34m🧹 Pruning cargo-llvm-cov target tree + stale shmem files...\033[0m\n"

    TARGET_DIR="${CARGO_TARGET_DIR:-target}"
    printf "   target dir: %s\n" "$TARGET_DIR"

    FREED_KB=0

    # Phase 1 - llvm-cov instrumentation trees.
    for sub in llvm-cov-target llvm-cov; do
        if [ -d "$TARGET_DIR/$sub" ]; then
            SIZE_KB=$(du -sk "$TARGET_DIR/$sub" 2>/dev/null | cut -f1 || echo 0)
            printf "   \033[0;34m•\033[0m %s/%s - %s KB\n" "$TARGET_DIR" "$sub" "$SIZE_KB"
            rm -rf "$TARGET_DIR/$sub"
            FREED_KB=$((FREED_KB + SIZE_KB))
        fi
    done

    # Phase 2 - stray .profraw instrumentation files.
    if [ -d "$TARGET_DIR" ]; then
        PROFRAW_COUNT=$(find "$TARGET_DIR" -name '*.profraw' -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "${PROFRAW_COUNT:-0}" -gt 0 ]; then
            PROFRAW_KB=$(find "$TARGET_DIR" -name '*.profraw' -type f -print0 2>/dev/null \
                | du -sk --files0-from=- 2>/dev/null \
                | awk '{sum += $1} END {print sum+0}')
            find "$TARGET_DIR" -name '*.profraw' -type f -delete 2>/dev/null || true
            printf "   \033[0;34m•\033[0m %s leftover *.profraw file(s) - %s KB\n" "$PROFRAW_COUNT" "${PROFRAW_KB:-0}"
            FREED_KB=$((FREED_KB + ${PROFRAW_KB:-0}))
        fi
    fi

    # Phase 3 - orphan daemon shmem files.
    # Paths mirror `dirs_next::data_local_dir().join("acmex/shmem")` which
    # is what the daemon writes through in `acmex_client::shmem`.
    case "$(uname -s)" in
        Darwin*)                     SHMEM_DIR="$HOME/Library/Application Support/acmex/shmem" ;;
        Linux*)                      SHMEM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/acmex/shmem" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
                                     SHMEM_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}/acmex/shmem" ;;
        *)                           SHMEM_DIR="" ;;
    esac
    if [ -n "$SHMEM_DIR" ] && [ -d "$SHMEM_DIR" ]; then
        SHMEM_COUNT=$(find "$SHMEM_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "${SHMEM_COUNT:-0}" -gt 0 ]; then
            SHMEM_KB=$(du -sk "$SHMEM_DIR" 2>/dev/null | cut -f1 || echo 0)
            rm -rf "$SHMEM_DIR"/*
            printf "   \033[0;34m•\033[0m %s shmem file(s) in %s - %s KB\n" "$SHMEM_COUNT" "$SHMEM_DIR" "$SHMEM_KB"
            FREED_KB=$((FREED_KB + SHMEM_KB))
        fi
    fi

    # Summary - promote to MB / GB for readability.
    if [ "$FREED_KB" -ge 1048576 ]; then
        printf "\033[0;32m✅ Freed ~%s GB\033[0m\n" "$((FREED_KB / 1048576))"
    elif [ "$FREED_KB" -ge 1024 ]; then
        printf "\033[0;32m✅ Freed ~%s MB\033[0m\n" "$((FREED_KB / 1024))"
    elif [ "$FREED_KB" -gt 0 ]; then
        printf "\033[0;32m✅ Freed %s KB\033[0m\n" "$FREED_KB"
    else
        printf "\033[0;32m✅ Nothing to clean - llvm-cov tree and shmem dir already empty.\033[0m\n"
    fi

