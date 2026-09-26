#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# =============================================================================
# adopt.sh: bring the rust-forge scaffolding to an EXISTING project
# =============================================================================
# The reverse of the init ceremony: instead of bringing your identity to the
# template, this brings the template's MACHINERY to your code. Read
# docs/forge/ADOPTING.md first; it explains the staged ladder this script starts.
#
# Contract (the never-erase rules):
#   * runs only in a clean git worktree, on a fresh branch it creates, and
#     COMMITS the whole trial there: keep = merge the branch, undo =
#     `just adopt-undo` (bit-for-bit restoration)
#   * copies ONLY files you do not have; where a file exists, the template's
#     version is written alongside as <name>.forge-suggested and listed
#     (exception: missing artifact entries are APPENDED to your .gitignore)
#   * wires your workspace automatically, but every edit is validated with
#     `cargo metadata` and reverted on failure; lints land at ALLOW (inert);
#     forge-adopt-snippets.md records what was done + manual fallbacks
#
# Usage, from the ROOT of your repository:
#   curl -fsSL https://raw.githubusercontent.com/skyllc-ai/rust-forge-template/main/adopt.sh | bash
#   bash adopt.sh [--slug myproj] [--template OWNER/REPO] [--yes]
#
# UPGRADE mode (a repo that is already forged or adopted):
#   curl -fsSL https://raw.githubusercontent.com/skyllc-ai/rust-forge-template/main/adopt.sh | bash -s -- --upgrade
#   bash adopt.sh --upgrade [--template OWNER/REPO|/local/checkout] [--yes] [--keep-toolchain]
#   (`just forge-upgrade` wraps this in adopted/forged repos)
#
#   Brings the machinery to the template's CURRENT state on a new branch
#   `forge/upgrade-<version>`, without erasing local changes:
#     * every machinery file is 3-way merged: base = the template at the
#       commit recorded in docs/forge/FORGE-STAMP.toml (`template-commit`)
#       or, when unknown, the newest template revision whose rendering
#       equals your copy; ours = your file; theirs = the template's HEAD.
#       Untouched files fast-forward; edited files merge; a conflict keeps
#       yours and writes the template's version as <name>.forge-suggested
#     * the lint posture is merged KEY BY KEY: lints the template added
#       land in your [workspace.lints.*] tables with their comments (at
#       "allow" when your posture is still at allow, i.e. an adoption
#       ratchet in progress); lints whose level you changed are kept and
#       reported; lints the template dropped (renamed/removed upstream)
#       are reported, never deleted
#     * clippy.toml keys the template added are appended
#     * the toolchain pin follows the template (--keep-toolchain keeps yours)
#     * generated hooks are regenerated from the merged gates.toml
#     * the stamp records the new template version + commit
#   Undo = delete the branch. Keep = merge it through the normal flow.

set -euo pipefail

C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_OFF='\033[0m'
say()  { printf "\n${C_BLUE}%s${C_OFF}\n" "$1"; }
ok()   { printf "  ${C_GREEN}OK %s${C_OFF}\n" "$1"; }
note() { printf "  ${C_CYAN}%s${C_OFF}\n" "$1"; }
warn() { printf "  ${C_YELLOW}!  %s${C_OFF}\n" "$1"; }
die()  { printf "  ${C_YELLOW}X  %s${C_OFF}\n" "$1"; exit 1; }

YES=0; SLUG=""; TEMPLATE="skyllc-ai/rust-forge-template"; UPGRADE=0; KEEP_TOOLCHAIN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) YES=1 ;;
        --upgrade) UPGRADE=1 ;;
        --keep-toolchain) KEEP_TOOLCHAIN=1 ;;
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

# ---- The machinery subset (shared by adopt and upgrade) ---------------------
# Deliberately NOT included: crates/ product skeleton, README/GETTING-STARTED/
# COMPONENTS (template-specific; upgrade adds them for init-born repos),
# LICENSE/LICENSES (yours), CHANGELOG, bootstrap.sh/adopt.sh/tools (template
# entry points), release-plz.toml + CITATION/TRADEMARK (opt-in later via
# docs/forge/COMPONENTS.md), supply-chain/ beyond config.toml (yours).
MACHINERY=(
    justfile just scripts/ci scripts/ci-pipeline scripts/hooks
    .cargo/config.toml .cargo/mutants.toml .config/nextest.toml .claude/settings.json
    .github/workflows .github/dependabot.yml
    deny.toml .taplo.toml .typos.toml clippy.toml rustfmt.toml
    rust-toolchain.toml supply-chain/config.toml
    crates/acmex-version packaging/macos/acmex.entitlements packaging/homebrew/acmex.rb
    AGENTS.md docs/policies docs/forge/ADOPTING.md docs/forge/CODE-SIGNING.md
    docs/forge/FORGE-STAMP.toml docs/forge/TEMPLATE_VERSION
)
# Template docs that are the project's docs when the project was BORN from
# the template (`origin = "init"`); an adopted repo keeps its own.
MACHINERY_INIT_DOCS=(docs/forge/COMPONENTS.md docs/forge/GETTING-STARTED.md docs/forge/README.md)
# Never merged: regenerated from the merged gates.toml, or stamped explicitly.
UPGRADE_SKIP=(scripts/hooks/_lint_fast.sh scripts/hooks/_lint_pre_push.sh
              docs/forge/FORGE-STAMP.toml docs/forge/TEMPLATE_VERSION supply-chain/config.toml)

# ============================================================================
# UPGRADE MODE: bring an already forged/adopted repo to the template's HEAD
# ============================================================================
render_identity() { # sets the placeholder -> project substitution table
    CAP="$(printf '%s' "${SLUG:0:1}" | tr '[:lower:]' '[:upper:]')${SLUG:1}"
    UP="$(printf '%s' "$SLUG" | tr '[:lower:]' '[:upper:]')"
    SLUG_IDENT="${SLUG//-/_}"; CAP_IDENT="${CAP//-/_}"; UP_IDENT="${UP//-/_}"
    # Identity the init ceremony rewrote beyond the slug, recovered from the
    # repo itself so a rendered template file compares equal to an untouched
    # copy: the GitHub org from the repository URL, the legal entity from the
    # stamp's copyright line. Best effort; a miss only costs a fast-forward
    # (the file then goes through the 3-way merge or lands as a suggestion).
    ORG="$(sed -n 's#^repository *= *"https://github.com/\([^/"]*\)/.*#\1#p' Cargo.toml | head -1)"
    ENTITY="$(sed -n 's/^# Copyright (c) [0-9-]* \(.*\)$/\1/p' docs/forge/FORGE-STAMP.toml | head -1)"
    # `just init` also rewrites the license expression when the project is
    # not MIT OR Apache-2.0 (a proprietary LicenseRef-* id in every header).
    LICENSE="$(sed -n 's/^license *= *"\([^"]*\)".*/\1/p' Cargo.toml | head -1)"
    [[ "$LICENSE" == "MIT OR Apache-2.0" ]] && LICENSE=""
    AUTHOR="$(sed -n 's/^authors *= *\["\([^"]*\)".*/\1/p' Cargo.toml | head -1)"
    DOMAIN="$(grep -ohE '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[A-Za-z]+' .github/workflows/ci-failure-notify.yml 2>/dev/null | head -1 | sed 's/.*@//')"
    [[ -n "$DOMAIN" ]] || DOMAIN="${ORG:-$SLUG}.example"
    # Winget-style capitalized org segment (`my-org` -> `MyOrg`), as `just init` does.
    ORG_CAP="$(printf '%s' "${ORG:-${SLUG}-org}" | awk -F- '{for (i=1;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}')"
}
render_file() { # SRC DST: the same substitution table as `just init`, most specific first
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    AUTHOR="$AUTHOR" ENTITY="$ENTITY" DOMAIN="$DOMAIN" ORG="$ORG" ORG_CAP="$ORG_CAP" CAP="$CAP" LICENSE="$LICENSE" \
    perl -pe '
        s/Acmex Placeholder Dev <dev\@acmex\.example>/$ENV{AUTHOR}/g if $ENV{AUTHOR};
        s/Acmex Placeholder LLC/$ENV{ENTITY}/g if $ENV{ENTITY};
        s/MIT OR Apache-2\.0/$ENV{LICENSE}/g if $ENV{LICENSE};
        s/acmex\.example/$ENV{DOMAIN}/g if $ENV{DOMAIN};
        s/acmex-org/$ENV{ORG}/g if $ENV{ORG};
        s/acmex-owner/$ENV{ORG}/g if $ENV{ORG};
        s/AcmexOrg\.Acmex/$ENV{ORG_CAP}.$ENV{CAP}/g if $ENV{ORG_CAP};
    ' "$src" > "$dst"
    case "$dst" in
        *.rs) perl -pi -e "s/acmex/${SLUG_IDENT}/g; s/Acmex/${CAP_IDENT}/g; s/ACMEX/${UP_IDENT}/g" "$dst" ;;
        *)    perl -pi -e "s/acmex/${SLUG}/g; s/Acmex/${CAP}/g; s/ACMEX/${UP}/g" "$dst" ;;
    esac
}
# The "unmodified modulo rename + reformat" test. `just init` reflows
# comments (rustfmt wraps the longer renamed identifiers) and rewrites
# copyright lines, so a byte comparison would call every renamed file
# edited. The fingerprint drops copyright lines, comment prefixes and all
# whitespace, which survives both while still catching real edits.
fingerprint() { grep -viE 'copyright' "$1" | sed -E 's@^[[:space:]]*(//[!/]?|#)[[:space:]]?@@' | tr -d '[:space:]'; }
same_fingerprint() { cmp -s <(fingerprint "$1") <(fingerprint "$2"); }
same_modulo_copyright() { same_fingerprint "$1" "$2"; }
fingerprint_distance() { diff <(fingerprint "$1" | fold -w 80) <(fingerprint "$2" | fold -w 80) | grep -c '^[<>]' || true; }
template_files_at() { # COMMIT: every machinery file path at that template commit
    local commit="$1" p
    for p in "${MACHINERY[@]}" "${EXTRA_DOCS[@]}"; do
        git -C "$TMPL_DIR" ls-tree -r --name-only "$commit" -- "$p" 2>/dev/null
    done | sort -u
}
dest_path() { printf '%s' "${1//acmex/$SLUG}"; }
recipe_names() { grep -hE '^[a-zA-Z_][a-zA-Z0-9_-]*[^:]*:([^=]|$)' "$1" 2>/dev/null | grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*' | sort -u; }

if [[ $UPGRADE -eq 1 ]]; then
    say "rust-forge upgrade: bring the machinery to the template's current state"
    [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$(pwd -P)" ]] || die "run this from the ROOT of your git repository (a linked worktree is fine)"
    [[ -f Cargo.toml ]] || die "no Cargo.toml here; this kit is for Rust projects"
    [[ -f docs/forge/FORGE-STAMP.toml ]] || die "no docs/forge/FORGE-STAMP.toml: this repo was never forged or adopted - run adopt.sh without --upgrade"
    [[ -z "$(git status --porcelain)" ]] || die "working tree not clean; commit or stash first"
    command -v python3 >/dev/null || die "python3 is required for the lint-posture merge"
    SLUG="$(sed -n 's/^project *= *"\([^"]*\)".*/\1/p' docs/forge/FORGE-STAMP.toml | head -1)"
    [[ -n "$SLUG" ]] || die "docs/forge/FORGE-STAMP.toml has no project = \"...\" line"
    OLD_VER="$(sed -n 's/^template-version *= *"\([^"]*\)".*/\1/p' docs/forge/FORGE-STAMP.toml | head -1)"
    OLD_COMMIT="$(sed -n 's/^template-commit *= *"\([^"]*\)".*/\1/p' docs/forge/FORGE-STAMP.toml | head -1)"
    ORIGIN="$(sed -n 's/^origin *= *"\([^"]*\)".*/\1/p' docs/forge/FORGE-STAMP.toml | head -1)"
    render_identity
    note "project: $SLUG   origin: ${ORIGIN:-init}   baseline: ${OLD_VER:-?} @ ${OLD_COMMIT:-unknown}   template: $TEMPLATE"

    TMPL_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMPL_DIR"' EXIT
    say "1/6 Fetching the template (with history, for the merge bases)"
    if [[ -d "$TEMPLATE/.git" ]]; then
        git clone --quiet "$TEMPLATE" "$TMPL_DIR"
    else
        git clone --quiet "https://github.com/${TEMPLATE}.git" "$TMPL_DIR"
    fi
    NEW_COMMIT="$(git -C "$TMPL_DIR" rev-parse HEAD)"
    NEW_VER="$(tr -d '[:space:]' < "$TMPL_DIR/docs/forge/TEMPLATE_VERSION")"
    ok "template ${NEW_VER} at ${NEW_COMMIT:0:10}"
    if [[ "$OLD_COMMIT" == "$NEW_COMMIT" ]]; then
        ok "already at the template's HEAD; nothing to do"; exit 0
    fi
    if [[ -n "$OLD_COMMIT" && "$OLD_COMMIT" != "unknown" ]] && ! git -C "$TMPL_DIR" cat-file -e "${OLD_COMMIT}^{commit}" 2>/dev/null; then
        warn "recorded template-commit ${OLD_COMMIT:0:10} is not in the template's history - falling back to per-file baseline search"
        OLD_COMMIT="unknown"
    fi
    EXTRA_DOCS=()
    [[ "${ORIGIN:-init}" == "init" ]] && EXTRA_DOCS=("${MACHINERY_INIT_DOCS[@]}")

    BRANCH="forge/upgrade-${NEW_VER}"
    if git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
        die "branch $BRANCH already exists - an upgrade is in progress. Finish it (merge) or delete the branch, then re-run."
    fi
    confirm "Create branch $BRANCH and merge the template's machinery in?" || die "aborted"
    BASE_BRANCH="$(git branch --show-current)"
    [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(git rev-parse HEAD)"   # detached HEAD (a worktree): the commit is the base
    git config forge.upgradeBase "$BASE_BRANCH"
    git switch -c "$BRANCH"

    # ---- 2. Per-file 3-way merge --------------------------------------------
    say "2/6 Merging machinery files (fast-forward / 3-way / suggested)"
    WORK="$(mktemp -d)"; trap 'rm -rf "$TMPL_DIR" "$WORK"' EXIT
    FF=(); MERGED=(); NEAREST=(); CONFLICTS=(); SUGGESTED=(); NEW=(); KEPT=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        for skip in "${UPGRADE_SKIP[@]}"; do [[ "$p" == "$skip" ]] && continue 2; done
        dest="$(dest_path "$p")"
        theirs="$WORK/theirs"; ours="$WORK/ours"; base="$WORK/base"
        git -C "$TMPL_DIR" show "${NEW_COMMIT}:${p}" > "$WORK/raw" 2>/dev/null || continue
        render_file "$WORK/raw" "$theirs"
        if [[ ! -e "$dest" ]]; then
            mkdir -p "$(dirname "$dest")"; cp "$theirs" "$dest"; NEW+=("$dest"); continue
        fi
        cp "$dest" "$ours"
        if cmp -s "$ours" "$theirs" || same_modulo_copyright "$ours" "$theirs"; then continue; fi
        # Base: the recorded template commit, else the newest template
        # revision of this file whose rendering equals our copy (an
        # untouched file at an unknown baseline).
        have_base=0
        if [[ -n "$OLD_COMMIT" && "$OLD_COMMIT" != "unknown" ]]; then
            if git -C "$TMPL_DIR" show "${OLD_COMMIT}:${p}" > "$WORK/rawbase" 2>/dev/null; then
                render_file "$WORK/rawbase" "$base"; have_base=1
            fi
        else
            # Unknown baseline: walk the file's template history. An exact
            # fingerprint match means "unmodified at that revision" (fast-
            # forward). Otherwise the NEAREST revision (smallest distance)
            # becomes the base for a real 3-way merge, so a repo that edited
            # the file still receives the template's changes since then;
            # a wrong-but-close base surfaces as conflict markers, never as
            # silent corruption, and the report names these files.
            nearest_dist=-1
            while IFS= read -r c; do
                git -C "$TMPL_DIR" show "${c}:${p}" > "$WORK/rawbase" 2>/dev/null || continue
                render_file "$WORK/rawbase" "$WORK/cand"
                if same_fingerprint "$ours" "$WORK/cand"; then have_base=1; cp "$ours" "$base"; nearest_dist=0; break; fi
                d="$(fingerprint_distance "$ours" "$WORK/cand")"
                if [[ $nearest_dist -lt 0 || $d -lt $nearest_dist ]]; then nearest_dist=$d; cp "$WORK/cand" "$base"; have_base=2; fi
            done < <(git -C "$TMPL_DIR" log --format=%H -n 80 -- "$p")
        fi
        if [[ $have_base -eq 0 ]]; then
            # No template history for this path at all (renamed upstream?):
            # the template's version lands beside yours for a manual merge.
            cp "$theirs" "${dest}.forge-suggested"; SUGGESTED+=("$dest"); continue
        fi
        if same_fingerprint "$ours" "$base"; then
            cp "$theirs" "$dest"; FF+=("$dest"); continue
        fi
        if same_fingerprint "$theirs" "$base"; then KEPT=$((KEPT + 1)); continue; fi
        base_label="template@${OLD_COMMIT:0:10}"; [[ $have_base -eq 2 ]] && base_label="template@nearest"
        if git merge-file -p -L "yours" -L "$base_label" -L "template@${NEW_COMMIT:0:10}" "$ours" "$base" "$theirs" > "$WORK/merged"; then
            cp "$WORK/merged" "$dest"
            if [[ $have_base -eq 2 ]]; then NEAREST+=("$dest"); else MERGED+=("$dest"); fi
        else
            cp "$theirs" "${dest}.forge-suggested"; CONFLICTS+=("$dest")
        fi
    done < <(template_files_at "$NEW_COMMIT")
    # Executable bits for the hook/script files the template carries.
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        dest="$(dest_path "$p")"; [[ -f "$dest" ]] && chmod +x "$dest"
    done < <(git -C "$TMPL_DIR" ls-tree -r "$NEW_COMMIT" | awk '$1 == "100755" {print $4}' | grep -E '^(scripts/|just/|justfile|adopt.sh|bootstrap.sh)' || true)
    # A NEW just file must not redefine a recipe an existing file already
    # has: just's recipe namespace is flat across imports and one collision
    # breaks EVERY recipe. Such a file lands as a suggestion instead.
    for i in "${!NEW[@]}"; do
        f="${NEW[$i]}"
        case "$f" in just/*.just) ;; *) continue ;; esac
        clash="$(comm -12 <(recipe_names "$f") <(for o in just/*.just justfile; do [[ "$o" == "$f" ]] || recipe_names "$o"; done | sort -u))"
        if [[ -n "$clash" ]]; then
            mv "$f" "${f}.forge-suggested"; unset 'NEW[i]'; SUGGESTED+=("$f")
            # The merged justfile may already import it; an import of a
            # missing file breaks every recipe, so park the line with a note.
            if [[ -f justfile ]] && grep -qE "^import '${f}'" justfile; then
                perl -pi -e "s{^import '\Q${f}\E'.*}{# import '${f}'  # forge upgrade: resolve ${f}.forge-suggested (recipe-name collision), then re-enable}" justfile
            fi
            warn "$f defines recipe(s) you already have ($(printf '%s' "$clash" | tr '\n' ' ')) - left as $f.forge-suggested (its justfile import is commented out); rename yours or theirs, then move it into place"
        fi
    done
    # A SUGGESTED just file (conflict, or no baseline) often carries recipes
    # the repo already defines elsewhere - typically because the template
    # ported them FROM this repo. Say so, so the manual merge starts with
    # the collision list instead of `just` refusing a redefined recipe.
    for f in "${CONFLICTS[@]}" "${SUGGESTED[@]}"; do
        case "$f" in just/*.just) ;; *) continue ;; esac
        [[ -f "${f}.forge-suggested" ]] || continue
        clash="$(comm -12 <(recipe_names "${f}.forge-suggested") <(for o in just/*.just justfile; do [[ "$o" == "$f" ]] || recipe_names "$o"; done | sort -u))"
        [[ -n "$clash" ]] && note "   $f.forge-suggested also defines recipe(s) another file of yours already has: $(printf '%s' "$clash" | tr '\n' ' ')"
    done
    ok "fast-forwarded ${#FF[@]}, merged ${#MERGED[@]} (+${#NEAREST[@]} against a nearest baseline), new ${#NEW[@]}, kept ${KEPT} (yours newer), conflicts ${#CONFLICTS[@]}, suggested ${#SUGGESTED[@]}"
    for f in "${NEAREST[@]}"; do note "   MERGED    $f  (3-way against the nearest template revision - review the diff)"; done
    for f in "${CONFLICTS[@]}"; do note "   CONFLICT  $f  (yours kept; template's version at $f.forge-suggested)"; done
    for f in "${SUGGESTED[@]}"; do note "   SUGGESTED $f  (no template history for this path; template's version at $f.forge-suggested)"; done
    if [[ ${#CONFLICTS[@]} -gt 0 || ${#SUGGESTED[@]} -gt 0 ]]; then
        warn "a tool crate or generator may not compile until every suggestion above is resolved (they move together)"
    fi
    if [[ $KEEP_TOOLCHAIN -eq 1 ]]; then
        git checkout -q -- rust-toolchain.toml 2>/dev/null || true
        note "   rust-toolchain.toml kept (--keep-toolchain)"
    fi
    if [[ -e .gitignore ]] && ! grep -qxF '*.forge-suggested' .gitignore; then
        printf '\n# added by rust-forge upgrade (manual-merge suggestions)\n*.forge-suggested\n' >> .gitignore
    fi

    # ---- 3. Lint posture + clippy.toml, key by key --------------------------
    say "3/6 Merging the lint posture (new lints land; your levels are kept)"
    export FORGE_TMPL="$TMPL_DIR" FORGE_NEW_VER="$NEW_VER"
    python3 - <<'PYLINT'
import os, re, sys
tmpl = os.environ["FORGE_TMPL"]; new_ver = os.environ["FORGE_NEW_VER"]
KEY = re.compile(r"^([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*$")

def tables(text, names):
    """{table: (start_line, end_line_exclusive, {key: line_index})} over the text's lines."""
    lines = text.split("\n"); out = {}; current = None; start = None
    for i, line in enumerate(lines + ["[end]"]):
        if line.startswith("["):
            if current in names:
                out[current] = (start, i, {})
            current = line.strip().strip("[]").strip(); start = i + 1
    for name, (a, b, keys) in out.items():
        for i in range(a, b):
            m = KEY.match(lines[i])
            if m and not lines[i].lstrip().startswith("#"):
                keys[m.group(1)] = i
    return lines, out

def level_of(value):
    m = re.search(r'level\s*=\s*"(\w+)"', value) or re.match(r'"(\w+)"', value.strip())
    return m.group(1) if m else None

def merge_file(path, names, label):
    ours_text = open(path).read(); theirs_text = open(os.path.join(tmpl, path)).read()
    ours_lines, ours = tables(ours_text, names)
    theirs_lines, theirs = tables(theirs_text, names)
    added, differ, dropped = [], [], []
    # ratchet detection: an adopted posture still at allow keeps new lints inert
    all_levels = [level_of(ours_lines[i].split("#")[0].split("=", 1)[1]) for t in ours.values() for i in t[2].values()]
    at_allow = all_levels and sum(1 for l in all_levels if l == "allow") > len(all_levels) / 2
    inserts = {}  # table -> lines to append
    for name in names:
        if name not in theirs: continue
        _, _, tkeys = theirs[name]
        okeys = ours.get(name, (None, None, {}))[2]
        for key, ti in tkeys.items():
            line = theirs_lines[ti]
            if key in okeys:
                tv = level_of(line.split("#")[0].split("=", 1)[1]); ov = level_of(ours_lines[okeys[key]].split("#")[0].split("=", 1)[1])
                if tv and ov and tv != ov: differ.append((name, key, ov, tv))
                continue
            if at_allow:
                line = re.sub(r'level\s*=\s*"(deny|warn|forbid)"', 'level = "allow"', line)
                line = re.sub(r'=\s*"(deny|warn|forbid)"', '= "allow"', line, count=1)
            marker = f"(added by forge {new_ver})"
            line = f"{line} {marker}" if "#" in line else f"{line}  # {marker}"
            inserts.setdefault(name, []).append(line)
            added.append((name, key))
        for key in okeys:
            if key not in tkeys: dropped.append((name, key))
    # apply: append at the end of each table (before the next header), keeping comments
    out = list(ours_lines)
    for name in sorted(inserts, key=lambda n: -ours[n][1] if n in ours else 0):
        if name in ours:
            _, end, _ = ours[name]
            # back up over trailing blank lines so the block stays inside the table
            while end > 0 and out[end - 1].strip() == "": end -= 1
            out[end:end] = inserts[name]
        else:
            out += ["", f"[{name}]"] + inserts[name]
    if inserts:
        open(path, "w").write("\n".join(out))
    print(f"  {label}: added {len(added)}" + (" at ALLOW (your posture is still at allow - ratchet in progress)" if at_allow and added else "") +
          f", levels you changed {len(differ)}, keys the template no longer has {len(dropped)}")
    for name, key in added: print(f"     + [{name}] {key}")
    for name, key, ov, tv in differ: print(f"     ~ [{name}] {key}: yours {ov}, template {tv} (kept yours)")
    for name, key in dropped: print(f"     ? [{name}] {key}: not in the template any more (renamed/removed upstream? left in place)")

merge_file("Cargo.toml", ["workspace.lints.clippy", "workspace.lints.rust", "workspace.lints.rustdoc"], "Cargo.toml lints")
if os.path.exists("clippy.toml"):
    ours = open("clippy.toml").read(); theirs = open(os.path.join(tmpl, "clippy.toml")).read()
    okeys = {m.group(1) for m in (KEY.match(l) for l in ours.split("\n")) if m}
    new = [l for l in theirs.split("\n") if (m := KEY.match(l)) and m.group(1) not in okeys]
    if new:
        open("clippy.toml", "a").write(f"\n# ── added by forge {new_ver} ──\n" + "\n".join(new) + "\n")
    print(f"  clippy.toml: added {len(new)} keys" + (": " + ", ".join(KEY.match(l).group(1) for l in new) if new else ""))
PYLINT
    if command -v taplo >/dev/null 2>&1; then
        taplo fmt Cargo.toml clippy.toml >/dev/null 2>&1 && note "   taplo: Cargo.toml and clippy.toml re-formatted (the pre-commit taplo gate)"
    fi

    # ---- 4. Workspace wiring the tool crates need (idempotent) --------------
    say "4/6 Checking the workspace wiring the tool crates need"
    if [[ "${ORIGIN:-init}" == "adopted" ]]; then
        export FORGE_SLUG="$SLUG" FORGE_UPGRADE=1
        if cargo metadata --format-version 1 --no-deps >/dev/null 2>&1; then
            ok "workspace resolves after the merge"
        else
            warn "cargo metadata fails after the merge; inspect the conflicts above before regenerating hooks"
        fi
    else
        cargo metadata --format-version 1 --no-deps >/dev/null 2>&1 && ok "workspace resolves after the merge" || warn "cargo metadata fails after the merge; inspect the conflicts above"
    fi

    # ---- 5. Stamp + regenerate what is generated ----------------------------
    say "5/6 Stamping the new baseline and regenerating the hooks"
    perl -pi -e "s/^template-version = .*/template-version = \"$NEW_VER\"/" docs/forge/FORGE-STAMP.toml
    if grep -q '^template-commit = ' docs/forge/FORGE-STAMP.toml; then
        perl -pi -e "s/^template-commit = .*/template-commit = \"$NEW_COMMIT\"/" docs/forge/FORGE-STAMP.toml
    else
        printf '# The template commit the machinery was last synced to (adopt.sh --upgrade).\ntemplate-commit = "%s"\n' "$NEW_COMMIT" >> docs/forge/FORGE-STAMP.toml
    fi
    printf '%s\n' "$NEW_VER" > docs/forge/TEMPLATE_VERSION
    ok "stamp: ${OLD_VER:-?} -> ${NEW_VER} @ ${NEW_COMMIT:0:10}"
    if [[ ${#CONFLICTS[@]} -eq 0 ]] && cargo metadata --format-version 1 --no-deps >/dev/null 2>&1; then
        if cargo run -q --release -p "${SLUG}-gen-hooks" -- --target pre-push >/dev/null 2>&1 \
           && cargo run -q --release -p "${SLUG}-gen-hooks" -- --target pre-commit >/dev/null 2>&1; then
            ok "hooks regenerated from the merged gates.toml"
        else
            warn "hook regeneration failed - run: cargo run -p ${SLUG}-gen-hooks -- --target pre-push (and pre-commit) after resolving"
        fi
        cargo generate-lockfile >/dev/null 2>&1 || true
        # A toolchain bump brings a newer rustfmt (comment reflow rules
        # change between nightlies); format now so the fmt gate is green
        # on the first `just check` instead of failing on files you did
        # not touch.
        if [[ $KEEP_TOOLCHAIN -eq 0 ]] && cargo fmt --all >/dev/null 2>&1; then
            ok "cargo fmt --all under the new toolchain"
        fi
    else
        warn "hooks NOT regenerated (conflicts or unresolvable workspace): resolve, then run cargo run -p ${SLUG}-gen-hooks for both targets"
    fi

    # ---- 6. Commit the upgrade on its branch ---------------------------------
    say "6/6 Committing the upgrade (reversible by design)"
    git add -A
    if git commit -q -m "chore(forge): upgrade the forge machinery to ${NEW_VER}" -m "Template ${TEMPLATE} @ ${NEW_COMMIT} (was ${OLD_VER:-?} @ ${OLD_COMMIT:-unknown}). Automated by adopt.sh --upgrade; see docs/forge/ADOPTING.md."; then
        ok "committed on $BRANCH (base: $BASE_BRANCH)"
        echo
        printf "${C_GREEN}Done. The upgrade is committed on %s; %s is untouched.${C_OFF}\n" "$BRANCH" "$BASE_BRANCH"
    else
        warn "the commit did not go through (your hooks, or commit signing - see the output above);"
        warn "everything is STAGED on $BRANCH: fix the cause and 'git commit' yourself, or 'just forge-upgrade-undo'"
        echo
        printf "${C_YELLOW}Done, but NOT committed: the upgrade is staged on %s; %s is untouched.${C_OFF}\n" "$BRANCH" "$BASE_BRANCH"
    fi
    if [[ ${#CONFLICTS[@]} -gt 0 || ${#SUGGESTED[@]} -gt 0 ]]; then
        printf "${C_YELLOW}Resolve the *.forge-suggested files listed above (diff against yours, take what you want, delete the suggestion), then commit.${C_OFF}\n"
    fi
    printf "${C_CYAN}Verify:   just setup && just go${C_OFF}\n"
    printf "${C_CYAN}Keep it:  push the branch and open a PR (normal flow)${C_OFF}\n"
    printf "${C_CYAN}Undo ALL: just forge-upgrade-undo   (back to %s, branch deleted)${C_OFF}\n" "$BASE_BRANCH"
    exit 0
fi

# ---- Preconditions ---------------------------------------------------------
say "rust-forge adopt: scaffolding for an existing project"
[[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$(pwd -P)" ]] || die "run this from the ROOT of your git repository (a linked worktree is fine)"
[[ -f Cargo.toml ]] || die "no Cargo.toml here; this kit is for Rust projects"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean; commit or stash first"
if [[ -f docs/forge/FORGE-STAMP.toml ]]; then
    die "this repo already has a forge stamp (docs/forge/FORGE-STAMP.toml) - already forged or adopted. If that's wrong (the file predates this repo's own history, or was copied in by hand), remove it and re-run."
fi
# The stamp lives on the adopt branch until that branch merges (adopt.sh
# never touches your base branch), so re-running from base while a trial
# is still in flight would NOT see it above - check for the branch too.
if git rev-parse --verify --quiet adopt/rust-forge-scaffolding >/dev/null; then
    die "branch adopt/rust-forge-scaffolding already exists - an adoption trial is in progress. 'just adopt-status' to see it, 'just adopt-undo' to discard it, or merge/delete the branch before re-running."
fi
command -v git >/dev/null || die "git is required"

SLUG="${SLUG:-$(ask "Short project slug (lowercase, for crate/tool names)" "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')")}"
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]] || die "slug '$SLUG' must match [a-z][a-z0-9-]*"
note "slug: $SLUG   template: $TEMPLATE"
confirm "Create branch adopt/rust-forge-scaffolding and copy the machinery in?" || die "aborted"

# ---- Branch + template checkout -------------------------------------------
BASE_BRANCH="$(git branch --show-current)"
[[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(git rev-parse HEAD)"   # detached HEAD: the commit is the base
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
# release-plz.toml + CITATION/TRADEMARK (opt-in later via docs/forge/COMPONENTS.md).
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

# ---- Detect just recipe-name collisions across files ------------------------
# just's recipes share one flat namespace across every imported .just file:
# two files defining the same recipe name breaks `just` entirely (not just
# that recipe), regardless of which files they live in. The never-clobber
# check above operates on FILE paths, so it cannot see this: a template file
# that's new to you (like just/analysis.just) can still collide with a
# recipe name already defined in a file of yours with a different name
# (like your own just/dev.just). Warn, don't block - same posture as the
# .forge-suggested list above.
if [[ -d just ]]; then
    COLLISIONS="$(
        for f in just/*.just; do
            [[ -f "$f" ]] || continue
            grep -hE '^[a-zA-Z_][a-zA-Z0-9_-]*' "$f" 2>/dev/null \
                | grep -E ':' | grep -vE ':=' \
                | grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*' \
                | sort -u \
                | while IFS= read -r name; do printf '%s\t%s\n' "$name" "$f"; done
        done | sort -u | awk -F'\t' '{c[$1]++; f[$1]=f[$1]" "$2} END{for (n in c) if (c[n]>1) print n":"f[n]}'
    )"
    if [[ -n "$COLLISIONS" ]]; then
        warn "recipe name(s) defined in more than one just/*.just file - 'just' will refuse to run until resolved:"
        printf '%s\n' "$COLLISIONS" | sort | while IFS= read -r line; do
            note "   ${line/:/  ->}"
        done
        note "   rename one side (e.g. audit: -> audit-legacy: in your own file) - never delete without checking what it did first"
    fi
fi

# If you already had a .gitignore we did not touch it; append (never
# overwrite) the entries the machinery's runtime artifacts need.
if [[ -e .gitignore ]]; then
    ADDED_IGNORES=""
    for pat in "target/" "build/" "*.forge-suggested"; do
        grep -qxF "$pat" .gitignore 2>/dev/null || ADDED_IGNORES="$ADDED_IGNORES$pat\n"
    done
    if [[ -n "$ADDED_IGNORES" ]]; then
        printf '\n# added by rust-forge adopt (machinery runtime artifacts)\n%b' "$ADDED_IGNORES" >> .gitignore
        ok ".gitignore: appended machinery artifact entries (yours untouched above)"
    fi
fi
if [[ ${#SUGGESTED[@]} -gt 0 ]]; then
    warn "${#SUGGESTED[@]} files already existed; template versions saved as *.forge-suggested:"
    for f in "${SUGGESTED[@]}"; do note "   $f  ->  $f.forge-suggested"; done
fi

# ---- Rename the placeholder to the slug ------------------------------------
say "3/6 Renaming the internal placeholder to '$SLUG'"
CAP="$(printf '%s' "${SLUG:0:1}" | tr '[:lower:]' '[:upper:]')${SLUG:1}"
UP="$(printf '%s' "$SLUG" | tr '[:lower:]' '[:upper:]')"
# Rust identifiers can't contain '-', but SLUG is validated as
# [a-z][a-z0-9-]* (kebab-case is the norm for crate/tool names). Package
# names and paths stay kebab-case (Cargo itself maps "foo-bar" -> the
# `foo_bar` module path at compile time); *.rs files need that mapping
# done here, or a hyphenated slug produces `use uffs-products_version;` -
# invalid syntax, silently breaking every copied tool crate.
SLUG_IDENT="${SLUG//-/_}"
CAP_IDENT="${CAP//-/_}"
UP_IDENT="${UP//-/_}"
# Only files we just created (never the user's own files).
git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
    case "$f" in *.forge-suggested) continue ;; esac
    case "$f" in
        *.rs) perl -pi -e "s/acmex/${SLUG_IDENT}/g; s/Acmex/${CAP_IDENT}/g; s/ACMEX/${UP_IDENT}/g" "$f" 2>/dev/null || true ;;
        *)    perl -pi -e "s/acmex/${SLUG}/g; s/Acmex/${CAP}/g; s/ACMEX/${UP}/g" "$f" 2>/dev/null || true ;;
    esac
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
# The copied stamp says origin = "init" (the template's own default, for
# `just init`); this run came through adopt.sh instead.
if [[ -f docs/forge/FORGE-STAMP.toml ]]; then
    perl -pi -e 's/^origin = "init"/origin = "adopted"/' docs/forge/FORGE-STAMP.toml
    TMPL_COMMIT="$(git -C "$TMPL_DIR" rev-parse HEAD)"
    perl -pi -e "s/^template-commit = .*/template-commit = \"$TMPL_COMMIT\"/" docs/forge/FORGE-STAMP.toml
fi

# ---- Snippets file: what to paste, nothing auto-edited ---------------------
say "4/6 Recording the wiring plan (forge-adopt-snippets.md)"
# Lints are delivered at ALLOW, not warn: the gates run clippy with
# -D warnings, so any warn-level lint would hard-fail the pipeline on a
# legacy codebase. allow = installed and inert; the ratchet (docs/forge/ADOPTING.md
# step 4) flips groups/lints straight to deny when a crate is ready.
LINTS_ALLOW="$(sed -n '/^\[workspace\.lints\.clippy\]/,/^\[profile\.dev\]/p' "$TMPL_DIR/Cargo.toml" | sed '$d' | sed 's/"deny"/"allow"/g; s/level = "deny"/level = "allow"/g; s/"warn"/"allow"/g')"
cat > forge-adopt-snippets.md <<EOF
# Paste these into your project (see docs/forge/ADOPTING.md for the full ladder)

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
${SLUG}-version = { path = "crates/${SLUG}-version", version = "<your workspace.package version, e.g. 0.1.0>" }
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
clean (docs/forge/ADOPTING.md step 4).

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
    # A `version = "0.0.0"` placeholder (cargo init's default in some
    # setups) is bumped to 0.1.0: the machinery's version tooling and the
    # copied tool crates expect a real 0.1.x start (field: iv, 2026-09).
    s, bumped = re.subn(r'(?m)^(\[workspace\.package\]\n(?:(?!^\[).*\n)*?version\s*=\s*)"0\.0\.0"',
                        lambda mm: mm.group(1) + '"0.1.0"', s)
    if bumped:
        print("  OK workspace.package.version 0.0.0 -> 0.1.0 (the machinery expects a 0.1.x start)")
    tbl_m = re.search(r"^\[workspace\.package\]\n((?:(?!^\[).*\n)*)", s, re.M)
    body = tbl_m.group(1)
    missing = "".join(f"{k} = {v}\n" for k, v in wp_keys.items()
                      if not re.search(rf"^{k}\s*=", body, re.M))
    if missing:
        s = s[:tbl_m.end(1)] + missing + s[tbl_m.end(1):]
# the tool crates need edition 2024
def fix_edition(mm):
    return mm.group(1) + '"2024"'
# (?m) only - NOT (?ms). The `s` (DOTALL) flag makes `.` match `\n`, which
# turns the repeated `(?:(?!^\[).*\n)*?` group into catastrophic
# backtracking (ReDoS) whenever the tail fails to match - e.g. an adoptee
# whose workspace.package is already edition = "2024" (nothing to bump).
# Sibling regex three lines up (tbl_m, same idiom) never had `s` and never
# hung; this is the fix, not a rewrite.
s = re.sub(r"(?m)^(\[workspace\.package\](?:(?!^\[).*\n)*?edition\s*=\s*)\"20(?:15|18|21)\"",
           fix_edition, s)

# 3. workspace.dependencies: add what is missing, merge features into what exists
# The internal version crate's requirement must match the workspace
# version it inherits, or cargo cannot resolve the path dependency
# ("failed to select a version for the requirement").
ws_ver_m = re.search(r"(?m)^\[workspace\.package\]\n(?:(?!^\[).*\n)*?version\s*=\s*\"([^\"]+)\"", s)
ws_version = ws_ver_m.group(1) if ws_ver_m else "0.1.0"
deps = {
 f"{slug}-version": f'{{ path = "crates/{slug}-version", version = "{ws_version}" }}',
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
# Resolve + commit the lockfile with the trial (committed-lock policy; also
# keeps the tree clean after your first build, so adopt-undo stays one command)
cargo generate-lockfile >/dev/null 2>&1 && ok "Cargo.lock resolved (committed with the trial)" || warn "could not resolve Cargo.lock; it will appear on first build"

# ---- Phase 6: commit the trial on the adopt branch --------------------------
# A plain commit: if YOUR pre-existing hooks reject it, that is your policy
# speaking; resolve and commit manually (or undo the branch). We never
# bypass anyone's hooks, including yours.
say "6/6 Committing the trial (reversible by design)"
git add -A
if git commit -q -m "chore(adopt): rust-forge scaffolding trial (automated; see docs/forge/ADOPTING.md)"; then
    ok "committed on adopt/rust-forge-scaffolding (base: $BASE_BRANCH)"
    COMMITTED=1
else
    warn "the commit did not go through (your hooks, or commit signing - see the output above);"
    warn "everything is staged on adopt/rust-forge-scaffolding: fix the cause and 'git commit' yourself, or 'just adopt-undo'"
    COMMITTED=0
fi

echo
if [[ $COMMITTED -eq 1 ]]; then
    printf "${C_GREEN}Done. Everything is committed on the adopt branch; your base branch is untouched.${C_OFF}\n"
else
    printf "${C_YELLOW}Done, but NOT committed: the trial is staged on the adopt branch; your base branch is untouched.${C_OFF}\n"
fi
printf "${C_CYAN}Try it:    just setup && just go${C_OFF}\n"
printf "${C_CYAN}Status:    just adopt-status${C_OFF}\n"
printf "${C_CYAN}Keep it:   push the branch and open a PR (normal flow)${C_OFF}\n"
printf "${C_CYAN}Undo ALL:  just adopt-undo   (bit-for-bit restoration, branch deleted)${C_OFF}\n"
printf "${C_CYAN}Then read docs/forge/ADOPTING.md: the lint ratchet (step 4) and the GitHub-side${C_OFF}\n"
printf "${C_CYAN}cutover (step 5; hooks/signing/rulesets are not branch-scoped).${C_OFF}\n"