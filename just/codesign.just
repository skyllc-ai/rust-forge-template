# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC

# ─────────────────────────────────────────────────────────────────────
# BINARY code signing (macOS). `just setup-signing` signs git COMMITS;
# this file signs the BINARIES you build, so macOS keeps recognising
# them across rebuilds. Different subject, deliberately parallel names.
#
# Why it matters: macOS privacy (TCC) keys a permission grant -
# Microphone, Input Monitoring, Full Disk Access, Photos - to the
# binary's Designated Requirement. For an unsigned or ad-hoc-signed
# binary the DR is its code hash, so EVERY `cargo build` is a new
# application in TCC's eyes and yesterday's grant silently stops
# applying. A certificate identity makes the DR "identifier +
# certificate", which survives rebuilds. A self-signed certificate in
# the login keychain is enough for development; nothing is
# distributed and no Apple developer account is involved.
#
# Identity preference (docs/forge/CODE-SIGNING.md):
#   1. ACMEX_CODESIGN_IDENTITY, when set (any codesigning identity name
#      in the keychain, e.g. "Developer ID Application: Your Org (TEAMID)")
#   2. a "Developer ID Application:" identity in the keychain, when
#      exactly one exists (also notarisable; hardened runtime and
#      packaging/macos/acmex.entitlements are applied)
#   3. the self-signed `acmex-dev` from `just setup-codesign`
#
# Setup once:  just setup-codesign
# Build+sign:  just build-signed [debug|release]
# Check:       just doctor-codesign
# ─────────────────────────────────────────────────────────────────────

# The identifier baked into every signature: TCC and the DR key on it,
# so it must be stable across builds and unique to this project.
codesign_identifier := env("ACMEX_CODESIGN_IDENTIFIER", "org.acmex-org.acmex")

# Resolve the signing identity by the preference ladder; prints the
# identity name, or nothing when none qualifies. Internal helper.

# Print the signing identity the preference ladder resolves to (internal).
_codesign-identity:
    #!/usr/bin/env bash
    set -uo pipefail
    [[ "$(uname -s)" == "Darwin" ]] || exit 0
    if [[ -n "${ACMEX_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$ACMEX_CODESIGN_IDENTITY"; exit 0
    fi
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    dev_ids=$(printf '%s\n' "$identities" | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' | sort -u || true)
    count=$(printf '%s\n' "$dev_ids" | grep -c . || true)
    if [[ "$count" -eq 1 ]]; then
        printf '%s\n' "$dev_ids"; exit 0
    fi
    if [[ "$count" -gt 1 ]]; then
        printf "  \033[1;33m⚠  %s Developer ID identities in the keychain - set ACMEX_CODESIGN_IDENTITY to pick one:\033[0m\n" "$count" >&2
        printf '%s\n' "$dev_ids" | sed 's/^/     /' >&2
    fi
    if [[ "$identities" == *"acmex-dev"* ]]; then
        printf 'acmex-dev\n'; exit 0
    fi
    exit 0

# Sign every Mach-O executable in target/<profile> with the best
# available identity (macOS only; a silent no-op everywhere else).
#
# Cargo has no post-build hook (build.rs runs BEFORE the binary exists),
# so `just` is the seam: any recipe that produces binaries calls this at
# its tail, and binaries are signed whether they are installed or run
# straight out of target/. ACMEX_ALLOW_UNSIGNED=1 downgrades a missing
# identity from an error to a warning (CI without a keychain).

# Sign every Mach-O executable in target/<profile> with the best identity (macOS).
sign-binaries profile="release":
    #!/usr/bin/env bash
    set -uo pipefail
    [[ "$(uname -s)" == "Darwin" ]] || exit 0
    identity="$(just _codesign-identity)"
    if [[ -z "$identity" ]]; then
        if [[ "${ACMEX_ALLOW_UNSIGNED:-0}" == "1" ]]; then
            printf "  \033[1;33m⚠  no signing identity - leaving target/{{ profile }} ad-hoc (ACMEX_ALLOW_UNSIGNED=1)\033[0m\n"
            exit 0
        fi
        printf "  \033[0;31m❌ no code-signing identity in the keychain (Developer ID or acmex-dev)\033[0m\n"
        printf "     Fix:    just setup-codesign\n"
        printf "     Bypass: ACMEX_ALLOW_UNSIGNED=1 just sign-binaries {{ profile }}\n"
        exit 1
    fi
    extra=(--identifier "{{ codesign_identifier }}")
    if [[ "$identity" == "Developer ID Application:"* ]]; then
        extra+=(--options runtime --entitlements packaging/macos/acmex.entitlements)
    fi
    signed=0
    # Mach-O executables only: skip .d files, build dirs, and the .bak
    # copies a deploy may have left beside them.
    for f in target/{{ profile }}/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        case "$(file -b "$f")" in *Mach-O*) ;; *) continue;; esac
        codesign -f -s "$identity" "${extra[@]}" "$f" >/dev/null 2>&1 || {
            printf "  \033[0;31m❌ codesign failed for %s\033[0m\n" "$f"
            exit 1
        }
        signed=$((signed + 1))
    done
    printf "  \033[0;32m✅ signed %d binaries in target/{{ profile }} with %s\033[0m\n" "$signed" "$identity"

# Build the workspace and sign the result, in that order. Use instead
# of a bare `cargo build` while working on anything that asks macOS for
# a privacy-sensitive grant.

# Build the workspace and sign the binaries, in that order (macOS).
build-signed profile="debug":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{ profile }}" == "release" ]]; then cargo build --release --workspace; else cargo build --workspace; fi
    just sign-binaries {{ profile }}

# Create the local self-signed `acmex-dev` code-signing identity
# (macOS, idempotent, non-interactive). Only needed when no Developer
# ID is in the keychain.

# Create the local self-signed acmex-dev code-signing identity (macOS, idempotent).
setup-codesign:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "\033[0;34m🔏 Binary code-signing setup (acmex-dev identity)\033[0m\n"
    if [[ "$(uname -s)" != "Darwin" ]]; then
        printf "  \033[0;36mℹ️  not macOS - nothing to do (binary signing is a macOS/TCC concern)\033[0m\n"
        exit 0
    fi
    existing="$(just _codesign-identity)"
    if [[ "$existing" == "Developer ID Application:"* ]]; then
        printf "  \033[0;32m✅ %s present - preferred; no local identity needed\033[0m\n" "$existing"
        exit 0
    fi
    if security find-identity -p codesigning 2>/dev/null | grep -q acmex-dev; then
        printf "  \033[0;32m✅ acmex-dev identity already present - nothing to change\033[0m\n"
        exit 0
    fi
    # A purely LOCAL self-signed identity: no secrets, no trust decision
    # outside this keychain, nothing to distribute. That is why it can be
    # a recipe at all - unlike commit signing, where key issuance is an
    # identity decision that needs a human.
    #
    # Three things here were established by testing, not by reading docs
    # (donor project, 2026-08, verified end to end in a scratch keychain):
    #
    #  1. The certificate needs the code-signing EKU set explicitly.
    #  2. The PKCS#12 needs a REAL password. Exporting with an empty one
    #     makes `security import` fail with "MAC verification failed
    #     during PKCS12 import (wrong password?)". The password is a
    #     transport detail for a file that lives for milliseconds.
    #  3. OpenSSL 3 writes PKCS#12 with algorithms macOS Security cannot
    #     read, so it needs `-legacy`. LibreSSL - which is what
    #     /usr/bin/openssl is on a stock Mac - REJECTS `-legacy` and is
    #     already compatible. Hence try-then-fall-back rather than
    #     assuming either.
    #
    # What is NOT needed: a trust setting. codesign signs happily with an
    # untrusted self-signed identity (verified), so this recipe never
    # calls add-trusted-cert and never raises an authorization dialog.
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
    # Written with printf rather than a heredoc: a heredoc terminator
    # must sit at column 0, which would end the just recipe body.
    {
      printf '[ req ]\ndistinguished_name = dn\nprompt = no\nx509_extensions = codesign\n'
      printf '[ dn ]\nCN = acmex-dev\n'
      printf '[ codesign ]\nbasicConstraints = critical,CA:FALSE\n'
      printf 'keyUsage = critical,digitalSignature\n'
      printf 'extendedKeyUsage = critical,codeSigning\n'
    } > "$workdir/openssl.cnf"
    printf "  \033[0;36m→ generating a self-signed code-signing certificate\033[0m\n"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
        -days 3650 -config "$workdir/openssl.cnf" >/dev/null 2>&1
    pass="acmex-setup-$$"
    if ! openssl pkcs12 -export -legacy -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
        -name acmex-dev -out "$workdir/identity.p12" -passout "pass:$pass" >/dev/null 2>&1; then
        openssl pkcs12 -export -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
            -name acmex-dev -out "$workdir/identity.p12" -passout "pass:$pass" >/dev/null 2>&1
    fi
    if [[ ! -s "$workdir/identity.p12" ]]; then
        printf "  \033[0;31m❌ could not export a PKCS#12 identity with %s\033[0m\n" "$(openssl version)"
        exit 1
    fi
    printf "  \033[0;36m→ importing into the login keychain\033[0m\n"
    keychain="$HOME/Library/Keychains/login.keychain-db"
    if ! security import "$workdir/identity.p12" -k "$keychain" -P "$pass" \
        -T /usr/bin/codesign -T /usr/bin/security 2>&1 | head -3; then
        printf "  \033[0;31m❌ keychain import failed\033[0m\n"
        exit 1
    fi
    # Without this, the FIRST codesign call raises a keychain-access
    # dialog per binary - the exact papercut this lane exists to remove.
    # It may prompt ONCE for the login password; that is expected.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "" "$keychain" >/dev/null 2>&1 || true
    printf "  \033[0;32m✅ acmex-dev identity created\033[0m\n"
    just doctor-codesign

# Binary signing is a macOS/TCC concern; there is nothing to verify
# elsewhere - and the bash variant below cannot start under the Windows
# just shell, so the OS split IS the guard.

# Is the code identity stable across rebuilds? (macOS only; no-op elsewhere)
[windows]
[linux]
doctor-codesign:
    @echo "doctor-codesign: not macOS - binary signing is a macOS concern, nothing to check"

# Is the code identity stable across rebuilds? The TCC question: a
# designated requirement containing `cdhash` means the grant dies on
# the next rebuild; one containing `certificate` survives it.

# Is the code identity stable across rebuilds? The TCC question.
[macos]
doctor-codesign:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    ok()   { printf "  \033[0;32m✅ %s\033[0m\n" "$1"; }
    bad()  { printf "  \033[0;31m❌ %s\033[0m\n" "$1"; fail=1; }
    info() { printf "  \033[0;36mℹ️  %s\033[0m\n" "$1"; }
    printf "\033[0;34m🩺 Binary code-signing doctor\033[0m\n"
    identity="$(just _codesign-identity)"
    if [[ "$identity" == "Developer ID Application:"* ]]; then
        ok "$identity (notarisable)"
    elif [[ "$identity" == "acmex-dev" ]]; then
        ok "acmex-dev (local; fine for development, not distributable)"
    elif [[ -n "$identity" ]]; then
        ok "$identity (from ACMEX_CODESIGN_IDENTITY)"
    else
        bad "no signing identity (Developer ID or acmex-dev) - run: just setup-codesign"
    fi
    checked=0; hashed=()
    for dir in target/release target/debug; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -f "$f" && -x "$f" ]] || continue
            case "$f" in *.bak|*.old|*.new|*.d) continue;; esac
            case "$(file -b "$f")" in *Mach-O*) ;; *) continue;; esac
            checked=$((checked + 1))
            # Capture, THEN match. `codesign ... | grep -q` is wrong
            # under pipefail: grep -q closes the pipe at the first match,
            # codesign dies on SIGPIPE, and a correctly-signed binary is
            # reported as ad-hoc.
            dr=$(codesign -d -r- "$f" 2>&1 | sed -n 's/^designated => //p')
            case "$dr" in
                *certificate*) ;;
                *) hashed+=("$f");;
            esac
        done
    done
    if (( checked == 0 )); then
        info "no built binaries under target/ - build first: just build-signed"
    elif (( ${#hashed[@]} == 0 )); then
        ok "all $checked built binaries are certificate-pinned (the grant survives rebuilds)"
    else
        bad "${#hashed[@]} of $checked built binaries are hash-pinned (ad-hoc): ${hashed[*]}"
        printf "     A cdhash designated requirement means the TCC grant dies on the next rebuild.\n"
        printf "     Fix:  just sign-binaries release   (or: just build-signed)\n"
    fi
    if (( fail )); then
        printf "\033[0;31m❌ binary signing incomplete - expect repeated macOS privacy prompts.\033[0m\n" >&2
        exit 1
    fi
    printf "\033[0;32m✅ binary code identity is stable.\033[0m\n"

# Re-sign already-installed binaries in a directory (safe while they
# are running: each is signed as a copy, then swapped in by rename).

# Re-sign already-installed binaries in a directory (safe while running).
resign-installed bindir="~/.cargo/bin":
    #!/usr/bin/env bash
    set -uo pipefail
    [[ "$(uname -s)" == "Darwin" ]] || exit 0
    bindir="{{ bindir }}"; bindir="${bindir/#\~/$HOME}"
    printf "\033[0;34m🔏 Re-signing installed binaries in %s\033[0m\n" "$bindir"
    identity="$(just _codesign-identity)"
    if [[ -z "$identity" ]]; then
        printf "  \033[0;31m❌ no signing identity (Developer ID or acmex-dev) - run: just setup-codesign\033[0m\n"
        exit 1
    fi
    extra=(--identifier "{{ codesign_identifier }}")
    if [[ "$identity" == "Developer ID Application:"* ]]; then
        extra+=(--options runtime --entitlements packaging/macos/acmex.entitlements)
    fi
    # SIGN A COPY, THEN SWAP THE INODE. Signing in place rewrites a file
    # that running processes have mapped, and macOS then kills them as
    # signature-invalid. `mv` unlinks the old inode; anything still
    # running holds it open and finishes on it.
    signed=0; failed=0
    for f in "$bindir"/acmex*; do
        [[ -f "$f" && -x "$f" ]] || continue
        case "$f" in *.bak|*.old|*.new|*.sh) continue;; esac
        case "$(file -b "$f")" in *Mach-O*) ;; *) continue;; esac
        signature=$(codesign -dvv "$f" 2>&1)
        case "$signature" in *"Authority=$identity"*) continue;; esac
        staged="$f.new"
        cp -p "$f" "$staged" || { failed=$((failed + 1)); continue; }
        if codesign -f -s "$identity" "${extra[@]}" "$staged" >/dev/null 2>&1 && mv "$staged" "$f"; then
            printf "  \033[0;32m✅ %s\033[0m\n" "$(basename "$f")"
            signed=$((signed + 1))
        else
            rm -f "$staged"
            printf "  \033[0;31m❌ %s\033[0m\n" "$(basename "$f")"
            failed=$((failed + 1))
        fi
    done
    printf "  re-signed %d, failed %d (already-signed binaries were skipped)\n" "$signed" "$failed"
    (( failed )) && exit 1
    exit 0

# Push the Apple signing and notarization secrets from a gopass store to
# the repository's GitHub Actions secrets in one step, never by hand
# (docs/forge/CODE-SIGNING.md section 4 lists the paths). Files travel
# base64-encoded; release.yml decodes them. Re-run after a certificate
# or key rotates. Needs `gh` with admin and `gopass`.

# Push the Apple signing/notarization secrets from gopass to GitHub Actions secrets.
secrets-sync-apple prefix="keys/apple":
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gopass >/dev/null || { echo "gopass is required (or set the secrets by hand: docs/forge/CODE-SIGNING.md section 4)"; exit 1; }
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    p="{{ prefix }}"
    echo "syncing Apple signing secrets from gopass $p/* to $repo"
    gopass show -o "$p/team-id"                    | gh secret set APPLE_TEAM_ID --repo "$repo"
    gopass show -o "$p/signing-identity"           | gh secret set APPLE_SIGNING_IDENTITY --repo "$repo"
    gopass show -o "$p/developer-id-p12-password"  | gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD --repo "$repo"
    gopass cat "$p/developer-id-application.p12" | base64 | tr -d '\n' | gh secret set APPLE_DEVELOPER_ID_P12 --repo "$repo"
    gopass show -o "$p/asc-api-key-id"             | gh secret set APPLE_API_KEY_ID --repo "$repo"
    gopass show -o "$p/asc-api-issuer-id"          | gh secret set APPLE_API_ISSUER_ID --repo "$repo"
    gopass cat "$p/asc-api-key.p8" | base64 | tr -d '\n' | gh secret set APPLE_API_KEY_P8 --repo "$repo"
    gh secret list --repo "$repo" | grep -E "^APPLE_" || true
