# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.

# ACMEX packaging recipes: platform-native bundles + installers.
#
# These recipes wrap the thin shell scripts under `packaging/` with the
# build-release step and the status output the rest of the justfile uses.
# The heavy lifting (plist templating, freedesktop install layout) lives
# in packaging/*/ so the scripts also work outside `just`.

# Build a macOS .app bundle wrapping the release acmex binary.
#
# Output: dist/ACMEX.app (dist/ is gitignored — ephemeral build output).
dist-macos:
    @printf "\033[0;34m📦 Building macOS .app bundle...\033[0m\n"
    cargo build --release -p acmex-cli
    ./packaging/macos/bundle.sh target/release/acmex dist/ACMEX.app
    @printf "\033[0;32m✅ Bundle ready: dist/ACMEX.app\033[0m\n"

# Install ACMEX on Linux with desktop integration (requires sudo).
#
# Installs to /usr/local by default; override with `PREFIX=... just install-linux`.
install-linux:
    @printf "\033[0;34m📦 Installing ACMEX + desktop integration (sudo required)...\033[0m\n"
    cargo build --release -p acmex-cli
    sudo ./packaging/linux/install.sh target/release/acmex
    @printf "\033[0;32m✅ Install complete\033[0m\n"
