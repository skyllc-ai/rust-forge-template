#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# =============================================================================
# Dev-machine bootstrap — from bare macOS/Linux to "ready for `just setup`"
# =============================================================================
# Installs the base tooling this repo's machinery needs: compiler
# prerequisites, Homebrew (macOS, if missing), git, just, gh, jq, pipx+reuse,
# and rustup. Everything is idempotent and check-before-install; re-run any
# time. The repo-specific steps (`just init` / `just setup` /
# `just setup-signing`) run AFTER this, from inside the repo.
#
# Two ways to run it:
#
#   * Already cloned:            bash bootstrap.sh
#   * Bare machine (public repo):
#       curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/bootstrap.sh | bash
#     (private repos: download this file via the GitHub UI, or clone first)
#
# When run outside a repo checkout, it finishes by printing the exact
# commands to get the code onto the machine (create-from-template or clone).

set -euo pipefail

C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_OFF='\033[0m'
say()  { printf "${C_BLUE}%s${C_OFF}\n" "$1"; }
ok()   { printf "  ${C_GREEN}✅ %s${C_OFF}\n" "$1"; }
todo() { printf "  ${C_CYAN}→ %s${C_OFF}\n" "$1"; }
warn() { printf "  ${C_YELLOW}⚠  %s${C_OFF}\n" "$1"; }

OS="$(uname -s)"
say "🧰 Bootstrap: base tooling for $OS"

# ── 1. Compiler prerequisites ────────────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
    if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode command-line tools"
    else
        todo "Installing Xcode command-line tools (a dialog will appear)"
        xcode-select --install || true
        warn "Re-run this script after the command-line tools finish installing."
        exit 0
    fi
elif [[ "$OS" == "Linux" ]]; then
    if command -v cc >/dev/null 2>&1; then
        ok "C toolchain"
    elif command -v apt-get >/dev/null 2>&1; then
        todo "Installing build-essential + curl + git (needs sudo)"
        sudo apt-get update -qq && sudo apt-get install -y -qq build-essential curl git
    else
        warn "No apt-get and no C compiler — install your distro's build tools, then re-run."
        exit 1
    fi
fi

# ── 2. Package manager (macOS: Homebrew) ─────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew"
    else
        todo "Installing Homebrew (official installer; you may be asked for your password)"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Activate brew for THIS shell (Apple Silicon default path first)
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    fi
fi

# ── 3. Base tools: git, just, gh, jq, pipx ───────────────────────────
install_pkg() { # NAME
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1"
        return
    fi
    todo "Installing $1"
    if [[ "$OS" == "Darwin" ]]; then
        brew install "$1"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y -qq "$1" || {
            # `just` is not in older apt repos — fall back to the official
            # installer into ~/.local/bin.
            if [[ "$1" == "just" ]]; then
                mkdir -p "$HOME/.local/bin"
                curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh \
                    | bash -s -- --to "$HOME/.local/bin"
                export PATH="$HOME/.local/bin:$PATH"
            elif [[ "$1" == "gh" ]]; then
                warn "gh not in apt — see https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
            else
                warn "could not install $1 — install it manually and re-run"
            fi
        }
    fi
}
for tool in git just gh jq pipx; do install_pkg "$tool"; done

# ── 4. reuse (license-compliance gate) via pipx ──────────────────────
if command -v reuse >/dev/null 2>&1; then
    ok "reuse"
else
    todo "Installing reuse via pipx"
    pipx install reuse && pipx ensurepath || warn "pipx install reuse failed — the gate soft-skips; retry later"
fi

# ── 5. Rust via rustup ───────────────────────────────────────────────
if command -v rustup >/dev/null 2>&1; then
    ok "rustup ($(rustc --version 2>/dev/null || echo 'toolchain pending'))"
else
    todo "Installing rustup (official installer, default settings)"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
    # Activate cargo for THIS shell
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi

# ── 6. GitHub authentication ─────────────────────────────────────────
if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    todo "Authenticating gh (interactive — follow the prompts)"
    gh auth login
fi

# ── 7. Next steps ────────────────────────────────────────────────────
echo
if [[ -f justfile && -d .git ]]; then
    printf "${C_GREEN}🎉 Tooling ready. Continue inside this repo:${C_OFF}\n"
    printf "   ${C_CYAN}just setup && just setup-signing && just go${C_OFF}\n"
else
    printf "${C_GREEN}🎉 Tooling ready. Now get the code onto this machine:${C_OFF}\n"
    printf "   ${C_CYAN}# Start a NEW project from the template:${C_OFF}\n"
    printf "   ${C_CYAN}gh repo create my-org/myproj --template <owner>/rust-forge-template --private --clone && cd myproj${C_OFF}\n"
    printf "   ${C_CYAN}# ...or JOIN an existing project:${C_OFF}\n"
    printf "   ${C_CYAN}gh repo clone <owner>/<repo> && cd <repo>${C_OFF}\n"
    printf "   then: ${C_CYAN}just init ...${C_OFF} (new projects only), ${C_CYAN}just setup && just setup-signing && just go${C_OFF}\n"
fi
