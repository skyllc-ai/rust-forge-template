#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# =============================================================================
# Guided bootstrap — from a bare macOS/Linux machine to a green pipeline
# =============================================================================
# One script drives the whole journey, asking before every step:
#
#   docs gate  ->  prerequisites  ->  tools  ->  GitHub auth  ->  get the
#   repo (new-from-template or join-existing)  ->  init  ->  setup  ->
#   commit signing  ->  first `just go`
#
# Every step is idempotent and check-before-act: existing installs are
# detected (with an optional update offer), an existing GitHub login is
# reused (never pushed toward a second account), an already-cloned repo
# skips acquisition, an already-initialized project skips init.
#
# Usage:
#   bash bootstrap.sh [FLAGS]                             # after download/clone
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/bootstrap.sh \
#     | bash -s -- [FLAGS]                                # greenfield (public repo)
#
# Flags:
#   --yes                 unattended: auto-approve confirmations, install
#                         what is missing, skip optional updates. Auth:
#                         export GH_TOKEN (gh honors it). Signing: an
#                         EXISTING key (~/.ssh/id_ed25519, e.g. dropped by
#                         your fleet tooling) is wired up automatically; no
#                         key is ever GENERATED unattended — key issuance is
#                         an identity decision, not a bootstrap side effect.
#   --new OWNER/NAME      create a new project from the template and clone it
#   --join OWNER/REPO     clone an existing project built from the template
#   --template OWNER/REPO which template --new instantiates
#                         (default: acmex-org/acmex — override after forking)
#   --dir PATH            parent directory the project lands in (interactive
#                         runs ask; default: the current directory)
#   --public              make --new repos public (default: private)
#   --help                this text
#
# Fully unattended greenfield example:
#   ... | bash -s -- --yes --new my-org/myproj --template <owner>/rust-forge-template

set -euo pipefail

# ── Output helpers ───────────────────────────────────────────────────
C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_OFF='\033[0m'
say()  { printf "\n${C_BLUE}%s${C_OFF}\n" "$1"; }
ok()   { printf "  ${C_GREEN}✅ %s${C_OFF}\n" "$1"; }
note() { printf "  ${C_CYAN}%s${C_OFF}\n" "$1"; }
warn() { printf "  ${C_YELLOW}⚠  %s${C_OFF}\n" "$1"; }
die()  { printf "  ${C_YELLOW}✋ %s${C_OFF}\n" "$1"; exit 1; }

# ── Flags ────────────────────────────────────────────────────────────
YES=0; NEW=""; JOIN=""; TEMPLATE="acmex-org/acmex"; VISIBILITY="--private"; DEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) YES=1 ;;
        --new) NEW="${2:?--new needs OWNER/NAME}"; shift ;;
        --join) JOIN="${2:?--join needs OWNER/REPO}"; shift ;;
        --template) TEMPLATE="${2:?--template needs OWNER/REPO}"; shift ;;
        --dir) DEST="${2:?--dir needs a path}"; shift ;;
        --public) VISIBILITY="--public" ;;
        --help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
    shift
done

# ── Interaction plumbing ─────────────────────────────────────────────
# `curl | bash` hands stdin to the pipe, so prompts read the terminal
# directly. No terminal + no --yes => refuse rather than guess.
TTY=""
if { : < /dev/tty; } 2>/dev/null; then TTY="/dev/tty"; fi

# confirm "question" [default Y|N] -> 0 = yes
confirm() {
    local q="$1" def="${2:-Y}" ans
    if [[ $YES -eq 1 ]]; then return 0; fi
    [[ -n "$TTY" ]] || die "no terminal for prompts — re-run with --yes for unattended mode"
    if [[ "$def" == "Y" ]]; then
        printf "  ${C_CYAN}%s [Y/n] ${C_OFF}" "$q" > "$TTY"; read -r ans < "$TTY"
        [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
    else
        printf "  ${C_CYAN}%s [y/N] ${C_OFF}" "$q" > "$TTY"; read -r ans < "$TTY"
        [[ "$ans" =~ ^[Yy] ]]
    fi
}

# ask "prompt" [default] -> echoes the answer
ask() {
    local q="$1" def="${2:-}" ans
    if [[ $YES -eq 1 || -z "$TTY" ]]; then printf '%s' "$def"; return 0; fi
    if [[ -n "$def" ]]; then
        printf "  ${C_CYAN}%s [%s]: ${C_OFF}" "$q" "$def" > "$TTY"
    else
        printf "  ${C_CYAN}%s: ${C_OFF}" "$q" > "$TTY"
    fi
    read -r ans < "$TTY"
    printf '%s' "${ans:-$def}"
}

# Prompt-default principle: every ask() ships a meaningful default —
# PRECEDENCE first (remembered settings, existing config, choices made
# earlier in this run), CONVENTION second (platform-blessed locations,
# ecosystem norms). Nobody should have to invent an answer to proceed.

# Best-practice default for "where do projects live":
#   1. remembered forge.projectsDir   (precedence: you told us before)
#   2. ghq.root                       (precedence: ghq users configured it)
#   3. first existing conventional dir (~/Developer, ~/Projects, ...)
#   4. $PWD, unless it is $HOME       (running curl from $HOME must not
#                                      dump repos into the home root)
#   5. platform convention, created on use (~/Developer on macOS — the
#      Apple-recognized dev folder — else ~/projects)
default_projects_dir() {
    local d
    d=$(git config --global --get forge.projectsDir 2>/dev/null || true)
    [[ -n "$d" ]] && { printf '%s' "$d"; return; }
    d=$(git config --global --get ghq.root 2>/dev/null || true)
    [[ -n "$d" ]] && { printf '%s' "${d/#\~/$HOME}"; return; }
    for d in "$HOME/Developer" "$HOME/Projects" "$HOME/projects" "$HOME/dev" \
             "$HOME/src" "$HOME/code" "$HOME/github" "$HOME/workspace"; do
        [[ -d "$d" ]] && { printf '%s' "$d"; return; }
    done
    if [[ "$PWD" != "$HOME" ]]; then printf '%s' "$PWD"; return; fi
    if [[ "$(uname -s)" == "Darwin" ]]; then printf '%s' "$HOME/Developer"
    else printf '%s' "$HOME/projects"; fi
}

open_url() { # best-effort browser open
    if command -v open >/dev/null 2>&1; then open "$1" 2>/dev/null || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" 2>/dev/null || true
    else note "open manually: $1"; fi
}

OS="$(uname -s)"
IN_REPO=0
[[ -f justfile && -d .git ]] && IN_REPO=1

# ── Phase 0: docs gate ───────────────────────────────────────────────
say "🧭 rust-forge bootstrap — guided setup"
if [[ $YES -eq 0 && $IN_REPO -eq 0 ]]; then
    note "Before investing time, two short reads decide if this is for you:"
    note "  * README        — 'Is this template for you?' (the 30-second fit check)"
    note "  * GETTING-STARTED — what the whole journey looks like"
    if confirm "Open both on GitHub in your browser now?" N; then
        open_url "https://github.com/${TEMPLATE}#is-this-template-for-you"
        open_url "https://github.com/${TEMPLATE}/blob/main/GETTING-STARTED.md"
    fi
    confirm "Read enough — continue with the setup?" || die "no problem — re-run me when ready"
fi

# ── Phase 1: compiler prerequisites ──────────────────────────────────
say "1/7 Compiler prerequisites"
if [[ "$OS" == "Darwin" ]]; then
    if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode command-line tools"
    else
        confirm "Install Xcode command-line tools (Apple dialog will appear)?" || die "required — aborting"
        xcode-select --install || true
        warn "Re-run this script once the command-line tools finish installing."
        exit 0
    fi
elif [[ "$OS" == "Linux" ]]; then
    if command -v cc >/dev/null 2>&1; then
        ok "C toolchain"
    elif command -v apt-get >/dev/null 2>&1; then
        confirm "Install build-essential + curl + git via apt (needs sudo)?" || die "required — aborting"
        sudo apt-get update -qq && sudo apt-get install -y -qq build-essential curl git
    else
        die "no apt-get and no C compiler — install your distro's build tools, then re-run"
    fi
else
    die "unsupported OS: $OS (macOS and Linux are supported)"
fi

# ── Phase 2: package manager (macOS) ─────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
    say "2/7 Homebrew"
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew ($(brew --version | head -1))"
    else
        confirm "Install Homebrew (official installer; may ask for your password)?" || die "required on macOS — aborting"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    fi
else
    say "2/7 Package manager"; ok "using apt"
fi

# ── Phase 3: base tools ──────────────────────────────────────────────
say "3/7 Base tools (git, just, gh, jq, pipx, reuse)"
install_pkg() { # NAME
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        ok "$name present"
        # Present -> optional update, only when interactive (never in --yes:
        # unattended runs should be reproducible, not surprise-upgraded).
        if [[ $YES -eq 0 ]] && confirm "Check for a newer $name?" N; then
            if [[ "$OS" == "Darwin" ]]; then brew upgrade "$name" 2>/dev/null || note "$name already newest (or not brew-managed)"
            else sudo apt-get install -y -qq --only-upgrade "$name" 2>/dev/null || note "$name already newest"; fi
        fi
        return 0
    fi
    confirm "Install $name?" || die "$name is required — aborting"
    if [[ "$OS" == "Darwin" ]]; then
        brew install "$name"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y -qq "$name" || {
            if [[ "$name" == "just" ]]; then
                mkdir -p "$HOME/.local/bin"
                curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh \
                    | bash -s -- --to "$HOME/.local/bin"
                export PATH="$HOME/.local/bin:$PATH"
            elif [[ "$name" == "gh" ]]; then
                die "gh not in your apt repos — install per https://github.com/cli/cli/blob/trunk/docs/install_linux.md and re-run"
            else
                die "could not install $name — install it manually and re-run"
            fi
        }
    fi
    ok "$name installed"
}
for tool in git just gh jq pipx; do install_pkg "$tool"; done
if command -v reuse >/dev/null 2>&1; then
    ok "reuse present"
else
    confirm "Install reuse (license-compliance gate) via pipx?" \
        && { pipx install reuse && pipx ensurepath || warn "pipx install failed — the reuse gate soft-skips; retry later"; } \
        || note "skipped — the reuse gate soft-skips when absent"
fi

# ── Phase 4: Rust ────────────────────────────────────────────────────
say "4/7 Rust (rustup)"
if command -v rustup >/dev/null 2>&1; then
    ok "rustup present ($(rustc --version 2>/dev/null || echo 'toolchain pending'))"
    if [[ $YES -eq 0 ]] && confirm "Run 'rustup update' now?" N; then rustup update; fi
else
    confirm "Install Rust via rustup (official installer, default settings)?" || die "required — aborting"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi
note "The repo pins its own toolchain (rust-toolchain.toml) — rustup fetches it on first build."

# ── Phase 5: GitHub account + auth ───────────────────────────────────
say "5/7 GitHub"
if gh auth status >/dev/null 2>&1; then
    login=$(gh api user -q .login 2>/dev/null || echo "?")
    ok "already authenticated as '${login}'"
    if [[ $YES -eq 0 ]] && ! confirm "Continue as '${login}'?"; then
        note "gh supports multiple accounts — adding another login (your existing one stays)."
        gh auth login
    fi
else
    if [[ $YES -eq 1 ]]; then
        die "gh is not authenticated — for unattended runs export GH_TOKEN (a fine-grained PAT), or pre-run 'gh auth login'"
    fi
    if confirm "Do you already have a GitHub account?"; then
        gh auth login
    else
        note "Opening the signup page — create the (free) account, then come back."
        open_url "https://github.com/signup"
        confirm "Account created — continue to login?" || die "re-run me after signing up"
        gh auth login
    fi
fi

# ── Phase 6: get the repo ────────────────────────────────────────────
say "6/7 The repository"
if [[ $IN_REPO -eq 1 ]]; then
    ok "already inside a repo checkout — skipping acquisition"
else
    # Where should the project live? Your layout is yours (e.g.
    # ~/private/github) — discovery order: --dir flag, the remembered
    # `forge.projectsDir` git setting, then ask (default $PWD).
    REMEMBERED=$(git config --global --get forge.projectsDir 2>/dev/null || true)
    if [[ -z "$DEST" ]]; then
        DEST=$(ask "Parent directory for the project" "$(default_projects_dir)")
    fi
    DEST="${DEST/#\~/$HOME}"
    mkdir -p "$DEST" && cd "$DEST"
    ok "projects land in: $(pwd)"
    if [[ "$(pwd)" != "$REMEMBERED" && $YES -eq 0 ]] \
        && confirm "Remember $(pwd) as your projects directory for next time?" N; then
        git config --global forge.projectsDir "$(pwd)"
        ok "saved (git config --global forge.projectsDir)"
    fi

    mode=""
    if [[ -n "$NEW" ]]; then mode="new"
    elif [[ -n "$JOIN" ]]; then mode="join"
    else
        [[ -n "$TTY" ]] || die "outside a repo, unattended mode needs --new or --join"
        note "How does the code get onto this machine?"
        note "  1) NEW project from the template (fresh history, your repo)"
        note "  2) JOIN an existing project (clone it)"
        choice=$(ask "Choose 1 or 2" "1")
        [[ "$choice" == "2" ]] && mode="join" || mode="new"
    fi
    ACQUIRED=""
    if [[ "$mode" == "new" ]]; then
        tpl=$(ask "Template to instantiate (OWNER/REPO)" "$TEMPLATE")
        slug="${NEW:-$(ask "Your new repo (OWNER/NAME)" "$(gh api user -q .login 2>/dev/null)/myproj")}"
        confirm "Create ${slug} from template ${tpl} (${VISIBILITY#--}) and clone it here?" || die "aborted"
        gh repo create "$slug" --template "$tpl" "$VISIBILITY" --clone
        cd "$(basename "$slug")"
    else
        slug="${JOIN:-$(ask "Repo to clone (OWNER/REPO)" "")}"
        [[ -n "$slug" ]] || die "no repo given"
        confirm "Clone ${slug} here?" || die "aborted"
        gh repo clone "$slug"
        cd "$(basename "$slug")"
    fi
    ACQUIRED="$slug"
    ok "repo ready: $(pwd)"
fi

# ── Phase 7: inside the repo — init, setup, signing, first green run ─
say "7/7 Project setup"
# Never run the init ceremony on the TEMPLATE repository itself — only on
# copies made from it. GitHub's isTemplate flag is the authoritative signal.
IS_TEMPLATE_SELF="$(gh repo view --json isTemplate -q .isTemplate 2>/dev/null || echo false)"
if [[ "$IS_TEMPLATE_SELF" == "true" ]]; then
    warn "this checkout IS the template repository — init ceremony not applicable"
elif [[ -d tools/init ]]; then
    note "This copy still carries the template's placeholder identity."
    if confirm "Run the init ceremony now (renames it to YOUR project)?"; then
        # Precedence for defaults: the OWNER/NAME chosen at acquisition
        # (this run), else the checkout's own name + your gh login.
        acq="${NEW:-${ACQUIRED:-}}"
        if [[ -n "$acq" && "$acq" == */* ]]; then
            def_name="${acq##*/}"; def_org="${acq%%/*}"
        else
            def_name="$(basename "$(pwd)")"
            def_org="$(gh api user -q .login 2>/dev/null)"
        fi
        iname=$(ask "Project slug (lowercase, [a-z0-9-])" "$def_name")
        iorg=$(ask "GitHub org/user" "$def_org")
        ientity=$(ask "Legal entity for copyright lines" "${iorg} contributors")
        def_author="$(git config user.name 2>/dev/null || echo "$iorg") <$(git config user.email 2>/dev/null || echo "dev@${iorg}.example")>"
        iauthor=$(ask "Author (Name <email>)" "$def_author")
        just init "$iname" "$iorg" "$ientity" "$iauthor"
    else
        warn "skipped — run 'just init <name> <org>' before real work"
    fi
else
    ok "project already initialized"
fi
if confirm "Install all gate tools + wire the git hooks (just setup)?"; then just setup; fi
# Signing: never touch a working setup (GPG or SSH) — check first.
if just doctor-signing >/dev/null 2>&1; then
    ok "commit signing already configured and working — untouched"
elif [[ $YES -eq 1 ]]; then
    # Unattended: wire up a pre-provisioned key; never mint one.
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
        just setup-signing || warn "signing setup incomplete — run 'just setup-signing' later"
    else
        warn "no SSH key found — commit signing NOT configured (the pre-push gate will reject pushes)."
        warn "Fix: a human runs 'just setup-signing', or your fleet tooling pre-provisions ~/.ssh/id_ed25519."
    fi
elif confirm "Set up commit signing (required before your first push)?"; then
    just setup-signing || warn "signing setup incomplete — run 'just setup-signing' again later"
fi
if confirm "Prove the machine with a full validation run (just go)?"; then just go; fi

echo
printf "${C_GREEN}🎉 Bootstrap complete. Daily driving: edit -> just check -> commit -> push -> PR.${C_OFF}\n"
printf "${C_CYAN}   Next reads: GETTING-STARTED.md (daily loop + gate fix-it table), COMPONENTS.md (growing the project).${C_OFF}\n"
printf "${C_CYAN}   GitHub-side state (labels, lane variables, rulesets): bash scripts/ci/bootstrap-github.sh${C_OFF}\n"
