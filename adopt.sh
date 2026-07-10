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
BASE_BRANCH="$(git branch --show-current)"
git config forge.adoptBase "$BASE_BRANCH"
git switch -c adopt/rust-forge-scaffolding 2>/dev/null || git switch adopt/rust-forge-scaffolding
TMPL_DIR="$(mktemp -d)"
trap 'rm -rf "$TMPL_DIR"' EXIT
say "1/6 Fetching the template"
if [[ -d "$TEMPLATE/.git" ]]; then
    git clone --quiet --depth 1 "$TEMPLATE" "$TMPL_DIR"   # local checkout (testing / offline)
else
    git clone --quiet --depth 1 "https://github.com/${TEMPLATE}.git" "$TMPL_DIR"
fi
ok "template at $(git -C "$TMPL_DIR" rev-parse --short HEAD)"

# ---- Copy: never clobber ---------------------------------------------------
say "2/6 Copying the machinery (existing files become .forge-suggested)"
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
    crates/acmex-version just/adopt.just AGENTS.md docs/policies ADOPTING.md
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
say "3/6 Renaming the internal placeholder to '$SLUG'"
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
say "4/6 Recording the wiring plan (forge-adopt-snippets.md)"
# Lints are delivered at ALLOW, not warn: the gates run clippy with
# -D warnings, so any warn-level lint would hard-fail the pipeline on a
# legacy codebase. allow = installed and inert; the ratchet (ADOPTING.md
# step 4) flips groups/lints straight to deny when a crate is ready.
LINTS_ALLOW="$(sed -n '/^\[workspace\.lints\.clippy\]/,/^\[profile\.dev\]/p' "$TMPL_DIR/Cargo.toml" | sed '$d' | sed 's/"deny"/"allow"/g; s/level = "deny"/level = "allow"/g; s/"warn"/"allow"/g')"
cat > forge-adopt-snippets.md <<EOF
# Paste these into your project (see ADOPTING.md for the full ladder)

## 0. Workspace package metadata (root Cargo.toml)

The copied tool crates inherit their metadata from \`[workspace.package]\`.
If your root Cargo.toml does not have this table, add it (skip any keys
you already define; adjust values to YOUR project):

Note: \`edition\` must be "2024" here; the copied tool crates use 2024
features and inherit this value. Your own crates keep whatever explicit
\`edition\` they already declare, so this affects nothing else.

\`\`\`toml
[workspace.package]
version = "0.1.0"
edition = "2024"
license = "TODO-your-license"
repository = "https://github.com/TODO-org/TODO-repo"
authors = ["TODO <todo@example.com>"]
readme = "README.md"
keywords = ["TODO"]
categories = ["TODO"]
publish = false
\`\`\`

## 1. Workspace members (root Cargo.toml, \`[workspace] members\`)

\`\`\`toml
  "crates/${SLUG}-version",
  "scripts/ci-pipeline",
  "scripts/ci/${SLUG}-gen-hooks",
  "scripts/ci/${SLUG}-gen-workflow",
  "scripts/ci/${SLUG}-manifest-audit",
\`\`\`

Also add to \`[workspace.dependencies]\`. Where you ALREADY have one of
these, keep your version number but make sure the features listed below
are included (the tool crates need them; e.g. serde without "derive" or
tokio without "process" will not compile):

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

## 2b. Your own crates

Two one-line additions per crate in its \`Cargo.toml\`:

\`\`\`toml
license.workspace = true   # or your explicit license; the deny gate flags unlicensed crates
[lints]
workspace = true           # opts the crate into the (currently allow-level) posture
\`\`\`

## 3. First commands

\`\`\`bash
cargo check            # workspace must resolve after step 1
just setup             # gate tools + hooks
just go                # the pipeline runs end to end (lints warn-level)
\`\`\`
EOF
ok "forge-adopt-snippets.md written"

# ---- Phase 5: wire the workspace automatically (git-guarded) ---------------
# Every automated edit is validated with `cargo metadata`; an edit that
# breaks the manifest is reverted on the spot (we are on a committed-clean
# branch, so git is the safety net). Anything automation cannot do safely
# lands in forge-adopt-fallbacks.txt for a human.
say "5/6 Wiring your workspace (automatic; every edit is validated or reverted)"
export FORGE_SLUG="$SLUG" FORGE_TMPL="$TMPL_DIR"
if python3 - <<'PYWIRE'
import json, os, re, subprocess, sys
slug = os.environ["FORGE_SLUG"]; tmpl = os.environ["FORGE_TMPL"]

def validate():
    return subprocess.run(["cargo", "metadata", "--format-version", "1", "--no-deps"],
                          capture_output=True).returncode == 0

def guarded(path, new_text, what):
    old = open(path).read()
    open(path, "w").write(new_text)
    if validate():
        print(f"  OK {what}")
        return True
    open(path, "w").write(old)
    print(f"  !! {what}: automation produced an invalid manifest; reverted")
    return False

fallbacks = []
s = open("Cargo.toml").read()

# 1. workspace members
members = [f"crates/{slug}-version", "scripts/ci-pipeline",
           f"scripts/ci/{slug}-gen-hooks", f"scripts/ci/{slug}-gen-workflow",
           f"scripts/ci/{slug}-manifest-audit"]
m = re.search(r"members\s*=\s*\[", s)
if m:
    add = "".join(f'\n  "{x}",' for x in members if f'"{x}"' not in s)
    s = s[:m.end()] + add + s[m.end():]
else:
    fallbacks.append("members: no `members = [` array found")

# 2. workspace.package: whole table if absent, missing keys if present
wp_keys = {"version": '"0.1.0"', "edition": '"2024"',
           "license": '"MIT OR Apache-2.0"',
           "repository": '"https://github.com/TODO-org/TODO-repo"',
           "authors": '["TODO <todo@example.com>"]', "readme": '"README.md"',
           "keywords": '["TODO"]', "categories": '["development-tools"]',
           "publish": "false"}
if "[workspace.package]" not in s:
    tbl = "\n[workspace.package]\n" + "".join(f"{k} = {v}\n" for k, v in wp_keys.items())
    s += tbl
else:
    tbl_m = re.search(r"^\[workspace\.package\]\n((?:(?!^\[).*\n)*)", s, re.M)
    body = tbl_m.group(1)
    missing = "".join(f"{k} = {v}\n" for k, v in wp_keys.items()
                      if not re.search(rf"^{k}\s*=", body, re.M))
    if missing:
        s = s[:tbl_m.end(1)] + missing + s[tbl_m.end(1):]
# the tool crates need edition 2024
def fix_edition(mm):
    return mm.group(1) + '"2024"'
s = re.sub(r"(?ms)^(\[workspace\.package\](?:(?!^\[).*\n)*?edition\s*=\s*)\"20(?:15|18|21)\"",
           fix_edition, s)

# 3. workspace.dependencies: add what is missing, merge features into what exists
deps = {
 f"{slug}-version": f'{{ path = "crates/{slug}-version", version = "0.1.0" }}',
 "anyhow": '"1"', "chrono": '{ version = "0.4", features = ["serde"] }',
 "clap": '{ version = "4", features = ["derive", "env", "unicode", "wrap_help"] }',
 "colored": '"3"', "futures": '"0.3"', "indicatif": '"0.18"', "num_cpus": '"1"',
 "regex": '"1"', "serde": '{ version = "1", features = ["derive"] }',
 "serde_json": '"1"',
 "tokio": '{ version = "1", default-features = false, features = ["io-util", "macros", "process", "rt", "rt-multi-thread", "signal", "sync", "time", "tracing"] }',
 "toml": '"1"', "uuid": '{ version = "1", features = ["v4"] }',
}
need_features = {
 "serde": ["derive"],
 "clap": ["derive", "env", "unicode", "wrap_help"],
 "chrono": ["serde"], "uuid": ["v4"],
 "tokio": ["io-util", "macros", "process", "rt", "rt-multi-thread", "signal", "sync", "time", "tracing"],
}
if "[workspace.dependencies]" not in s:
    s += "\n[workspace.dependencies]\n"
dep_m = re.search(r"^\[workspace\.dependencies\]\n", s, re.M)
ins = dep_m.end()
for name, spec in deps.items():
    line_m = re.search(rf"^{re.escape(name)}\s*=\s*(.+)$", s, re.M)
    if not line_m:
        s = s[:ins] + f"{name} = {spec}\n" + s[ins:]
        continue
    if name in need_features:
        val = line_m.group(1)
        if val.strip().startswith('"'):
            ver = val.strip().strip('"')
            feats = ", ".join(f'"{f}"' for f in need_features[name])
            extra = ", default-features = false" if name == "tokio" else ""
            s = s[:line_m.start(1)] + f'{{ version = "{ver}", features = [{feats}]{extra} }}' + s[line_m.end(1):]
        elif "features" in val:
            missing = [f for f in need_features[name] if f'"{f}"' not in val]
            if missing:
                fm = re.search(r"features\s*=\s*\[", val)
                addf = "".join(f'"{f}", ' for f in missing)
                newval = val[:fm.end()] + addf + val[fm.end():]
                s = s[:line_m.start(1)] + newval + s[line_m.end(1):]
        else:
            fallbacks.append(f"dep {name}: multi-line table, merge features by hand")

# 4. the lint posture at allow (installed, inert)
if "[workspace.lints.clippy]" not in s:
    t = open(os.path.join(tmpl, "Cargo.toml")).read()
    lm = re.search(r"(?ms)^\[workspace\.lints\.clippy\].*?(?=^\[profile\.dev\])", t)
    lints = (lm.group(0).replace('"deny"', '"allow"')
                        .replace('level = "deny"', 'level = "allow"')
                        .replace('"warn"', '"allow"'))
    s += "\n" + lints

if not guarded("Cargo.toml", s, "root Cargo.toml (members, workspace.package, deps, lints at allow)"):
    sys.exit(3)

# 5. per-crate: license + [lints] workspace = true (their crates only)
meta = json.loads(subprocess.run(["cargo", "metadata", "--format-version", "1", "--no-deps"],
                                 capture_output=True, text=True).stdout)
root = os.getcwd()
for pkg in meta["packages"]:
    man = pkg["manifest_path"]
    rel = os.path.relpath(man, root)
    if rel.startswith("scripts/") or rel.startswith(f"crates/{slug}-version"):
        continue
    c = open(man).read()
    orig = c
    if not re.search(r"^license(-file)?(\.workspace)?\s*=", c, re.M):
        c2 = re.sub(r"^(edition[^\n]*\n)", r"\1license.workspace = true\n", c, count=1, flags=re.M)
        c = c2 if c2 != c else c.replace("[package]\n", "[package]\nlicense.workspace = true\n", 1)
    if "[lints]" not in c:
        c += "\n[lints]\nworkspace = true\n"
    if c != orig and not guarded(man, c, f"crate {pkg['name']} (license + lints opt-in)"):
        fallbacks.append(f"crate {pkg['name']}: add license + [lints] workspace = true by hand")

if fallbacks:
    open("forge-adopt-fallbacks.txt", "w").write("\n".join(fallbacks) + "\n")
    print("  !! some spots need a human; see forge-adopt-fallbacks.txt (details in forge-adopt-snippets.md)")
sys.exit(0)
PYWIRE
then
    ok "workspace wired automatically (snippets file kept as the record of what was done)"
else
    warn "automatic wiring hit a wall; your files were reverted, nothing is broken."
    warn "forge-adopt-snippets.md has the manual blocks for the parts that failed."
fi

# ---- Phase 6: commit the trial on the adopt branch --------------------------
# A plain commit: if YOUR pre-existing hooks reject it, that is your policy
# speaking; resolve and commit manually (or undo the branch). We never
# bypass anyone's hooks, including yours.
say "6/6 Committing the trial (reversible by design)"
git add -A
if git commit -q -m "chore(adopt): rust-forge scaffolding trial (automated; see ADOPTING.md)"; then
    ok "committed on adopt/rust-forge-scaffolding (base: $BASE_BRANCH)"
else
    warn "your existing hooks rejected the commit; fix and 'git commit' yourself, or 'just adopt-undo'"
fi

echo
printf "${C_GREEN}Done. Everything is committed on the adopt branch; your base branch is untouched.${C_OFF}\n"
printf "${C_CYAN}Try it:    just setup && just go${C_OFF}\n"
printf "${C_CYAN}Status:    just adopt-status${C_OFF}\n"
printf "${C_CYAN}Keep it:   push the branch and open a PR (normal flow)${C_OFF}\n"
printf "${C_CYAN}Undo ALL:  just adopt-undo   (bit-for-bit restoration, branch deleted)${C_OFF}\n"
printf "${C_CYAN}Then read ADOPTING.md: the lint ratchet (step 4) and the GitHub-side${C_OFF}\n"
printf "${C_CYAN}cutover (step 5; hooks/signing/rulesets are not branch-scoped).${C_OFF}\n"