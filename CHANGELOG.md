<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-11-10

### Template 1.1.3 (merge commits, quieter CI, fresh dependencies)

- Merge commits only, never squash: `just merge` defaults to a merge
  commit and refuses squash and rebase; `scripts/ci/main-ruleset.json`
  allows merge commits only (merge queue on MERGE, no linear-history rule)
  and `bootstrap-github.sh` sets the repo to merge commits only. The
  commit-signature gate now checks merge commits too, since a branch's
  merges reach `main` as they are.
- `just ship` no longer queues `gh pr merge --auto --squash` (refused under
  a merge-commit-only ruleset, and on a plan without required checks an
  auto-merge fires before any check has run): it opens the release PR and
  names `just merge <PR>`. It merges `origin/main` into the release branch
  instead of rebasing, so signed commits are never rewritten.
- The cargo-vet weekly refresh reports the refreshed imports (job summary
  and artifact) instead of opening a PR: opening a PR is the maintainer's
  call, and the job now needs read access only.
- The failure notifier watches every workflow that can fail on `main`,
  files a labelled issue for an unlisted one instead of dropping it, and
  mails `<repo>failed@nios.net` (also when filing the issue failed).
- The crates.io publish job installs the pinned toolchain (`rustup show`)
  instead of a floating, unpinned `dtolnay/rust-toolchain@nightly`.
- Toolchain nightly-2026-09-26 -> nightly-2026-11-10 (clippy, Windows and
  Linux cross gates green); dependencies at their latest
  releases (tokio 1.54.1, serde_json 1.0.154, toml 1.2.1, uuid 1.29.2 and
  the lockfile), every new version vetted (seven deltas reviewed and
  certified, nine exemptions retired by the refreshed imports); GitHub
  Actions pinned to their latest release SHAs.

### Template 1.1.2 (upgrade baseline fix)

- `adopt.sh --upgrade`: the template's HEAD is never a merge base. With an
  unknown baseline, the nearest-revision search could pick HEAD for a file
  you edited, which read as "yours is newer" and silently dropped the
  template's changes (docenta's `gen-workflow` never received the cargo-vet
  matcher). A file that no template revision before HEAD explains is now
  reported as UNMATCHED with the template's copy beside it, never kept
  silently; the nearest-revision distance is measured per line; a
  placeholder org is no longer treated as an identity to substitute.

### Template 1.1.1 (docenta's upgrade feedback)

- `unneeded_field_pattern` yields to `rest_pattern_accessible_field`: the
  two contradicted each other on any match arm that ignores every field of
  a struct variant (`Foo { .. }` vs `Foo { a: _, b: _ }`); exhaustive
  destructuring is the posture, so the all-ignored spelling is now the
  explicit one.
- `just init` derives the code-signing identifier from the project's domain
  (`com.skyllc.<slug>`), not from the GitHub org.
- The upgrade report names recipe collisions inside suggested just files
  (the template ports recipes FROM repos, so they come back as duplicates).
- ADOPTING.md: what to expect after an upgrade (`clippy --keep-going`, the
  line gate moving, `map_or_default`).
- A duplicated recipe description in `just/test.just`.

### Template 1.1.0 (the forge machinery; product code unchanged)

- Toolchain pinned to nightly-2026-09-26; dependencies refreshed and every
  new version vetted (publisher trust inherited from the family's imports,
  three deltas reviewed by hand, twelve exemptions retired).
- Three clippy lints new in this nightly added to the posture
  (`unnecessary_rest_pattern`, `rest_pattern_accessible_field`,
  `definition_in_module_root`) plus rustc's `raw_borrows_via_references`.
- `acmex-gen-workflow` checks four more properties across EVERY workflow:
  one pin per action, toolchain versions, per-target RUSTFLAGS and nextest
  profiles, declared once in `scripts/ci/gates.toml` (`[toolchain]`,
  `[[target]]`).
- `gate_when = "code_changed"` gates now run at pre-commit against the
  staged set (deletions included); `acmex-manifest-audit` discovers members
  by walking the whole tree.
- The push tier: the pre-push hook refuses direct, deleting and force pushes
  to `main`; `just merge` waits for every check and requires the aggregate
  to be present; `just pre-pr` rehearses the PR tier; `just pr` validates
  the title; `just protect-main` applies `scripts/ci/main-ruleset.json`;
  `main-merge-guard.yml` auto-reverts an unverified merge.
- lane:codesign: `just setup-codesign` / `build-signed` / `sign-binaries` /
  `doctor-codesign` / `resign-installed`, an entitlements file, and
  secrets-gated Developer ID signing + notarization in `release.yml`
  (`docs/forge/CODE-SIGNING.md`).
- lane:preview (`preview-artifacts.yml`), lane:brew (`brew-publish.yml` +
  formula template), an Intel macOS release target, `RELEASE_REPO`
  indirection for releases published from a separate public repository.
- `lint-ci-linux-zig` and `lint-ci-mac-intel` pre-push gates (soft-skip
  until the tools are installed); `just tier2-local`, `just bench`.
- Tier 2: cargo-udeps pinned with a driving-cargo prefetch; the mutants job
  on a pinned ubuntu-24.04 image judging by `missed.txt`; the config moved
  to `.cargo/mutants.toml`, the path cargo-mutants actually reads.
- `adopt.sh --upgrade` / `just forge-upgrade`: brings a forged or adopted
  repo to the template's current state (3-way machinery merge, key-by-key
  lint merge, toolchain pin, regenerated hooks) on a branch; the stamp
  records `template-commit`. `adopt.sh` bumps a `0.0.0` workspace version
  to `0.1.0` and matches the version crate's requirement to it.
- GitHub Actions pins refreshed to their latest releases; `deny.toml`
  ignores the workspace's own license; `sccache` detection no longer breaks
  `just` on Windows.

