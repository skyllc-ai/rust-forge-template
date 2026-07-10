#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# =============================================================================
# adopt.sh: bring the rust-forge scaffolding to an EXISTING project
# =============================================================================
# The reverse of the init ceremony: instead of bringing your identity to the
# template, this brings the template's MACHINERY to your code. Read
# ADOPTING.md first; it explains the staged ladder this script starts.
#
# Contract (the never-erase rules):
#   * runs only in a clean git worktree, and only on a fresh branch it creates
#   * copies ONLY files you do not have; where a file exists, the template's
#     version is written alongside as <name>.forge-suggested and listed
#   * never edits your Cargo.toml, your crates, or your lint levels; the
#     exact blocks to paste land in forge-adopt-snippets.md, lints at WARN
#
# Usage, from the ROOT of your repository:
#   curl -fsSL https://raw.githubusercontent.com/skyllc-ai/rust-forge-template/main/adopt.sh | bash
#   bash adopt.sh [--slug myproj] [--template OWNER/REPO] [--yes]

set -euo pipefail

C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_OFF='\033[0m'
say()  { printf "\n${C_BLUE}%s${C_OFF}\n" "$1"; }
ok()   { printf "  ${C_GREEN}OK %s${C_OFF}\n" "$1"; }
note() { printf "  ${C_CYAN}%s${C_OFF}\n" "$1"; }
warn() { printf "  ${C_YELLOW}!  %s${C_OFF}\n" "$1"; }
die()  { printf "  ${C_YELLOW}X  %s${C_OFF}\n" "$1"; exit 1; }

YES=0; SLUG=""; TEMPLATE="skyllc-ai/rust-forge-template"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) YES=1 ;;
        --slug) SLUG="${2:?--slug needs a value}"; shift ;;
        --template) TEMPLATE="${2:?--template needs OWNER/REPO}"; shift ;;
        --help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
    shift
done

TTY=""
if { : < /dev/tty; } 2>/dev/null; then TTY="/dev/tty"; fi
ask() {
    local q="$1" def="${2:-}" ans
    if [[ $YES -eq 1 || -z "$TTY" ]]; then printf '%s' "$def"; return 0; fi
    printf "  ${C_CYAN}%s [%s]: ${C_OFF}" "$q" "$def" > "$TTY"
    read -r ans < "$TTY"
    printf '%s' "${ans:-$def}"
}
confirm() {
    local q="$1" ans
    [[ $YES -eq 1 ]] && return 0
    [[ -n "$TTY" ]] || die "no terminal for prompts; re-run with --yes"
    printf "  ${C_CYAN}%s [Y/n] ${C_OFF}" "$q" > "$TTY"; read -r ans < "$TTY"
    [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# ---- Preconditions ---------------------------------------------------------
say "rust-forge adopt: scaffolding for an existing project"
[[ -d .git ]] || die "run this from the ROOT of your git repository"
[[ -f Cargo.toml ]] || die "no Cargo.toml here; this kit is for Rust projects"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean; commit or stash first"
if [[ -f justfile && -d scripts/ci ]]; then
    die "this repo already looks scaffolded (justfile + scripts/ci exist)"
fi
command -v git >/dev/null || die "git is required"

SLUG="${SLUG:-$(ask "Short project slug (lowercase, for crate/tool names)" "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')")}"
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]] || die "slug '$SLUG' must match [a-z][a-z0-9-]*"
note "slug: $SLUG   template: $TEMPLATE"
confirm "Create branch adopt/rust-forge-scaffolding and copy the machinery in?" || die "aborted"

# ---- Branch + template checkout -------------------------------------------
git switch -c adopt/rust-forge-scaffolding 2>/dev/null || git switch adopt/rust-forge-scaffolding
TMPL_DIR="$(mktemp -d)"
trap 'rm -rf "$TMPL_DIR"' EXIT
say "1/4 Fetching the template"
if [[ -d "$TEMPLATE/.git" ]]; then
    git clone --quiet --depth 1 "$TEMPLATE" "$TMPL_DIR"   # local checkout (testing / offline)
else
    git clone --quiet --depth 1 "https://github.com/${TEMPLATE}.git" "$TMPL_DIR"
fi
ok "template at $(git -C "$TMPL_DIR" rev-parse --short HEAD)"

# ---- Copy: never clobber ---------------------------------------------------
say "2/4 Copying the machinery (existing files become .forge-suggested)"
# Machinery-only subset. Deliberately NOT copied: crates/ product skeleton,
# README/GETTING-STARTED/COMPONENTS (template-specific), LICENSE/LICENSES
# (yours), CHANGELOG, bootstrap.sh/adopt.sh/tools (template entry points),
# release-plz.toml + CITATION/TRADEMARK (opt-in later via COMPONENTS.md).
MACHINERY=(
    justfile just scripts/ci scripts/ci-pipeline scripts/hooks
    .cargo/config.toml .config/nextest.toml .claude/settings.json
    .github/workflows .github/dependabot.yml
    deny.toml .taplo.toml .typos.toml clippy.toml rustfmt.toml
    rust-toolchain.toml supply-chain/config.toml
    crates/acmex-version AGENTS.md docs/policies ADOPTING.md
)
SUGGESTED=()
copied=0
copy_path() { # SRC_REL
    local rel="$1" src="$TMPL_DIR/$1"
    [[ -e "$src" ]] || return 0
    if [[ -d "$src" ]]; then
        while IFS= read -r -d '' f; do
            copy_path "${f#"$TMPL_DIR"/}"
        done < <(find "$src" -type f -print0)
        return 0
    fi
    local dest="$rel"
    if [[ -e "$dest" ]]; then
        cp "$src" "${dest}.forge-suggested"
        SUGGESTED+=("$dest")
    else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        copied=$((copied + 1))
    fi
}
for p in "${MACHINERY[@]}"; do copy_path "$p"; done
ok "copied $copied new files"
if [[ ${#SUGGESTED[@]} -gt 0 ]]; then
    warn "${#SUGGESTED[@]} files already existed; template versions saved as *.forge-suggested:"
    for f in "${SUGGESTED[@]}"; do note "   $f  ->  $f.forge-suggested"; done
fi

# ---- Rename the placeholder to the slug ------------------------------------
say "3/4 Renaming the internal placeholder to '$SLUG'"
CAP="$(printf '%s' "${SLUG:0:1}" | tr '[:lower:]' '[:upper:]')${SLUG:1}"
UP="$(printf '%s' "$SLUG" | tr '[:lower:]' '[:upper:]')"
# Only files we just created (never the user's own files).
git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
    case "$f" in *.forge-suggested) continue ;; esac
    perl -pi -e "s/acmex/${SLUG}/g; s/Acmex/${CAP}/g; s/ACMEX/${UP}/g" "$f" 2>/dev/null || true
done
# Path renames among the new files (deepest first)
while IFS= read -r -d '' p; do
    nn="$(dirname "$p")/$(basename "$p" | sed "s/acmex/${SLUG}/g")"
    [[ "$p" != "$nn" ]] && mv "$p" "$nn"
done < <(git ls-files --others --exclude-standard -z | grep -z 'acmex' | sort -rz)
# Directories containing the placeholder
for d in $(find . -type d -name '*acmex*' -not -path './.git/*' 2>/dev/null | sort -r); do
    mv "$d" "$(dirname "$d")/$(basename "$d" | sed "s/acmex/${SLUG}/g")"
done
ok "placeholder renamed in the new files only"

# ---- Snippets file: what to paste, nothing auto-edited ---------------------
say "4/4 Writing forge-adopt-snippets.md (paste-and-go blocks)"
# Lints are delivered at ALLOW, not warn: the gates run clippy with
# -D warnings, so any warn-level lint would hard-fail the pipeline on a
# legacy codebase. allow = installed and inert; the ratchet (ADOPTING.md
# step 4) flips groups/lints straight to deny when a crate is ready.
LINTS_ALLOW="$(sed -n '/^\[workspace\.lints\.clippy\]/,/^\[profile\.dev\]/p' "$TMPL_DIR/Cargo.toml" | sed '$d' | sed 's/"deny"/"allow"/g; s/level = "deny"/level = "allow"/g; s/"warn"/"allow"/g')"
cat > forge-adopt-snippets.md <<EOF
# Paste these into your project (see ADOPTING.md for the full ladder)

## 1. Workspace members (root Cargo.toml, \`[workspace] members\`)

\`\`\`toml
  "crates/${SLUG}-version",
  "scripts/ci-pipeline",
  "scripts/ci/${SLUG}-gen-hooks",
  "scripts/ci/${SLUG}-gen-workflow",
  "scripts/ci/${SLUG}-manifest-audit",
\`\`\`

Also add to \`[workspace.dependencies]\` (the tool crates need these; check
which you already have and keep YOUR versions):

\`\`\`toml
${SLUG}-version = { path = "crates/${SLUG}-version", version = "0.1.0" }
anyhow = "1"
chrono = { version = "0.4", features = ["serde"] }
clap = { version = "4", features = ["derive", "env", "unicode", "wrap_help"] }
colored = "3"
futures = "0.3"
indicatif = "0.18"
num_cpus = "1"
regex = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", default-features = false, features = ["io-util", "macros", "process", "rt", "rt-multi-thread", "signal", "sync", "time", "tracing"] }
toml = "1"
uuid = { version = "1", features = ["v4"] }
\`\`\`

## 2. The lint posture, delivered at ALLOW (installed, inert)

Paste into your root Cargo.toml, and add \`[lints] workspace = true\` to
each crate. Nothing changes yet: allow-level lints are silent, so every
gate stays exactly as green as your code is today.

Why not "warn"? The gates run clippy with \`-D warnings\`, which would
turn every warn into a hard failure on day one. Instead: SURVEY a group
ad hoc (no gate involved) with e.g.
\`cargo clippy --workspace -- -W clippy::pedantic\`, then RATCHET by
flipping that group or lint to "deny" in this block once a crate is
clean (ADOPTING.md step 4).

\`\`\`toml
${LINTS_ALLOW}
\`\`\`

## 3. First commands

\`\`\`bash
cargo check            # workspace must resolve after step 1
just setup             # gate tools + hooks
just go                # the pipeline runs end to end (lints warn-level)
\`\`\`
EOF
ok "forge-adopt-snippets.md written"

echo
printf "${C_GREEN}Done. Your code was not touched; nothing is enforced yet.${C_OFF}\n"
printf "${C_CYAN}Next: 1) paste the two blocks from forge-adopt-snippets.md${C_OFF}\n"
printf "${C_CYAN}      2) merge any *.forge-suggested files by hand${C_OFF}\n"
printf "${C_CYAN}      3) just setup && just go${C_OFF}\n"
printf "${C_CYAN}      4) read ADOPTING.md for the ratchet (steps 3-4)${C_OFF}\n"
printf "${C_CYAN}      5) git add -A && git commit when you like what you see${C_OFF}\n"