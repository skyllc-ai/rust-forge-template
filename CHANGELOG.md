<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
