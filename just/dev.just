# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.

# Watch mode development.
dev:
    @printf "\033[0;34m🔄 Starting watch mode...\033[0m\n"
    @if command -v cargo-watch >/dev/null 2>&1; then \
        cargo watch -x "nextest run --workspace --jobs 16" -x "clippy --workspace --all-targets --all-features --no-deps -- {{ test_flags }}"; \
    else \
        printf "\033[1;33mInstalling cargo-watch...\033[0m\n"; \
        just _install-if-missing cargo-watch cargo-watch; \
        cargo watch -x "nextest run --workspace --jobs 16" -x "clippy --workspace --all-targets --all-features --no-deps -- {{ test_flags }}"; \
    fi

# Clean build artifacts.
clean:
    @printf "\033[0;34m🧹 Cleaning build artifacts...\033[0m\n"
    cargo clean

# Emergency killswitch.
kill:
    @printf "\033[0;31m🚨 EMERGENCY: Killing all cargo processes...\033[0m\n"
    @pkill -f "cargo" 2>/dev/null || true
    @pkill -f "rustc" 2>/dev/null || true
    @printf "\033[0;32m✅ All cargo processes terminated\033[0m\n"

# Install cross-compilation targets for GitHub Actions compatibility.
setup-cross:
    @printf "\033[0;34m Installing cross-compilation targets...\033[0m\n"
    rustup target add x86_64-unknown-linux-gnu
    rustup target add aarch64-unknown-linux-gnu
    rustup target add x86_64-pc-windows-msvc
    @printf "\033[0;32m✅ Cross-compilation targets installed\033[0m\n"

# Cross-compile check for GitHub Actions compatibility.
check-cross:
    @printf "\033[0;34m Cross-compilation validation using CI pipeline...\033[0m\n"
    cargo run -q --release -p acmex-ci-pipeline -- cross-check

# Type-check all #[cfg(windows)] code paths from macOS using cargo-xwin.
#
# Catches missing imports, wrong types, and dead code in Windows-only blocks
# that `cargo check` on macOS silently skips - including `#[cfg(windows)]`
# tests, benches, and `std::os::windows::*` usage.  CI today only runs on
# Linux (`ubuntu-22.04`), so this recipe is the ONLY pre-PR gate that
# exercises Windows-specific code.
#
# Uses `--all-targets --all-features` so tests and benches are checked
# alongside libs and bins (this is how the Windows-only bench / test bugs
# that motivated this gate were surfaced).  Runs in ~2–5 s warm once
# xwin has cached the MSVC SDK under `~/Library/Caches/xwin/`.
check-windows:
    @printf "\033[0;34m🪟 Windows cross-check (cargo xwin check, all-targets all-features)...\033[0m\n"
    cargo xwin check --workspace --all-targets --all-features --target x86_64-pc-windows-msvc
    @printf "\033[0;32m✅ Windows cross-check passed\033[0m\n"

# Cross-platform compile check across all three supported targets.
#
# Runs native (host) + Linux (via cargo-zigbuild when `zig` is on PATH,
# else Docker `lint-ci-linux`) + Windows (via xwin, through
# `check-windows`).  Intended as a manual "pre-PR sweep"; the pre-push
# hook runs the host + Windows subset only (Linux is too slow for a
# commit-time gate - CI covers it).
#
# Linux path order (Phase L1.4 of windows-clippy-and-linux-cross-plan.md):
#   1. Prefer `just lint-ci-linux-zig` (native, ~10–20 s warm) when
#      `zig` and `cargo-zigbuild` are both available.
#   2. Fall back to `just lint-ci-linux` (Docker, authoritative -
#      mirrors CI's `rust:latest` image exactly).
#   3. Skip with a hint when neither is available.
#
# Skips silently if a prerequisite tool (cargo-xwin, zig, docker) is
# missing, but reports which targets were exercised so you know the
# coverage.
check-all-targets:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "\033[0;34m🌐 Cross-platform compile check (macOS + Linux + Windows)...\033[0m\n"
    printf "\033[0;36m   ── macOS (native host) ──\033[0m\n"
    cargo check --workspace --all-targets --all-features
    printf "\033[0;32m   ✅ native host\033[0m\n\n"
    printf "\033[0;36m   ── Windows x86_64-pc-windows-msvc (xwin) ──\033[0m\n"
    if command -v cargo-xwin >/dev/null 2>&1; then
        cargo xwin check --workspace --all-targets --all-features --target x86_64-pc-windows-msvc
        printf "\033[0;32m   ✅ Windows (xwin)\033[0m\n\n"
    else
        printf "\033[1;33m   ⚠  cargo-xwin not installed - skipping; install with: \033[0;36mcargo install cargo-xwin\033[0m\n\n"
    fi
    printf "\033[0;36m   ── Linux x86_64-unknown-linux-gnu ──\033[0m\n"
    if command -v zig >/dev/null 2>&1 && command -v cargo-zigbuild >/dev/null 2>&1; then
        printf "\033[0;36m   · using cargo-zigbuild (native, no Docker)\033[0m\n"
        just lint-ci-linux-zig
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf "\033[0;36m   · using Docker (authoritative; install \033[0;36mzig\033[0m + \033[0;36mcargo-zigbuild\033[0m for the faster path)\033[0m\n"
        just lint-ci-linux
    else
        printf "\033[1;33m   ⚠  Neither zigbuild nor Docker available - skipping; install one via \033[0;36mjust install-dev-tools\033[0m\n"
    fi
    printf "\033[0;32m✅ Cross-platform check complete\033[0m\n"


# Update everything: Rust toolchain, cargo tools, system packages.
# Uses cargo-binstall (pre-built binaries) when available for ~100× faster installs.
# Run before `just go` or `just ship` to stay cutting-edge.
[unix]
update-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "\033[1;34m🔄 Updating all development tools\033[0m\n"
    echo "========================================================"

    # ── 1. Rust toolchain ──────────────────────────────────────
    printf "\n\033[0;34m🦀 Step 1/3: Rust toolchain\033[0m\n"
    if command -v brew >/dev/null 2>&1 && brew list rustup 2>/dev/null | grep -q rustup; then
        printf "  → rustup managed by Homebrew\n"
        brew upgrade rustup 2>/dev/null || true
    else
        rustup self update 2>/dev/null || true
    fi
    rustup update
    just toolchain-sync
    printf "\033[0;32m  ✅ Rust toolchain up to date\033[0m\n"

    # ── 2. Cargo tools ─────────────────────────────────────────
    printf "\n\033[0;34m📦 Step 2/3: Cargo tools\033[0m\n"
    TOOLS=(
        cargo-nextest
        cargo-llvm-cov
        cargo-deny
        cargo-xwin
        sccache
        cargo-machete
        cargo-outdated
        cargo-semver-checks
        cargo-mutants
        cargo-insta
        rust-script
        flamegraph
        samply
    )
    TOOL_LIST="${TOOLS[*]}"
    if command -v cargo-binstall >/dev/null 2>&1; then
        printf "  → Using cargo-binstall (fast, pre-built binaries)\n"
        cargo binstall -y --no-confirm $TOOL_LIST
    else
        printf "  → Using cargo install (compiling from source - slower)\n"
        printf "  💡 Install cargo-binstall for ~100× faster updates:\n"
        printf "     curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash\n"
        cargo install $TOOL_LIST
    fi
    printf "\033[0;32m  ✅ Cargo tools up to date\033[0m\n"

    # ── 3. System packages ─────────────────────────────────────
    printf "\n\033[0;34m🍺 Step 3/3: System packages\033[0m\n"
    if command -v brew >/dev/null 2>&1; then
        brew upgrade just 2>/dev/null || printf "  → just already up to date\n"
    else
        printf "  → No Homebrew detected, skipping system packages\n"
    fi
    printf "\033[0;32m  ✅ System packages up to date\033[0m\n"

    echo ""
    printf "\033[1;32m🎉 All tools updated!\033[0m\n"
    printf "  rustc:    $(rustc --version)\n"
    printf "  nextest:  $(cargo nextest --version 2>/dev/null | head -1)\n"
    printf "  llvm-cov: $(cargo llvm-cov --version 2>/dev/null)\n"

[windows]
update-tools:
    #!powershell
    Write-Host "`n[update-tools] Updating all development tools" -ForegroundColor Blue
    Write-Host "========================================================"

    # --- 1. Rust toolchain ------------------------------------
    Write-Host "`n[Rust] Step 1/3: Rust toolchain" -ForegroundColor Blue
    rustup self update 2>$null
    rustup update
    just toolchain-sync
    Write-Host "  [OK] Rust toolchain up to date" -ForegroundColor Green

    # --- 2. Cargo tools ---------------------------------------
    Write-Host "`n[Pkg] Step 2/3: Cargo tools" -ForegroundColor Blue
    $tools = @(
        "cargo-nextest"
        "cargo-llvm-cov"
        "cargo-deny"
        "sccache"
        "cargo-machete"
        "cargo-outdated"
        "cargo-semver-checks"
        "cargo-mutants"
        "cargo-insta"
        "rust-script"
    )
    $toolList = $tools -join " "
    if (Get-Command cargo-binstall -ErrorAction SilentlyContinue) {
        Write-Host "  -> Using cargo-binstall (fast, pre-built binaries)"
        Invoke-Expression "cargo binstall -y --no-confirm $toolList"
    } else {
        Write-Host "  -> Using cargo install (compiling from source - slower)"
        Write-Host "  [TIP] Install cargo-binstall for faster updates:" -ForegroundColor Yellow
        Invoke-Expression "cargo install $toolList"
    }
    Write-Host "  [OK] Cargo tools up to date" -ForegroundColor Green

    # --- 3. System packages -----------------------------------
    Write-Host "`n[Pkg] Step 3/3: System packages" -ForegroundColor Blue
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget upgrade Casey.Just 2>$null
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        scoop update just 2>$null
    } else {
        Write-Host "  -> No winget/scoop detected, skipping system packages"
    }
    Write-Host "  [OK] System packages up to date" -ForegroundColor Green

    Write-Host "`n[DONE] All tools updated!" -ForegroundColor Green
    Write-Host "  rustc:    $(rustc --version)"
    Write-Host "  nextest:  $(cargo nextest --version 2>$null | Select-Object -First 1)"


