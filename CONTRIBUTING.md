<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# Contributing to ACMEX

Thanks for helping improve ACMEX.

> By contributing you agree your contribution is dual-licensed under [MIT OR Apache-2.0](LICENSE) and that the ACMEX name and logo remain governed by [TRADEMARK.md](TRADEMARK.md).

## Contact

- **Bug reports, feature requests, questions:** open a GitHub issue on [acmex-org/acmex](https://github.com/acmex-org/acmex/issues).
- **Brand / trademark questions:** open an issue tagged `brand`, or email [`trademark@acmex.example`](mailto:trademark@acmex.example).
- **Commercial / partnership inquiries:** [`partnerships@acmex.example`](mailto:partnerships@acmex.example), or a [discussion](https://github.com/acmex-org/acmex/discussions) with the `commercial-interest` label.
- **Organization:** [Acmex Placeholder LLC](https://github.com/acmex-org).

## Toolchain and setup

- Use the pinned nightly toolchain from `rust-toolchain.toml`.
- `just` is the primary workflow entry point.

Recommended setup:

1. Install the nightly toolchain: `rustup toolchain install nightly`
2. Install `just`: `cargo install just`
3. Install the common contributor toolchain: `just setup`
4. List available workflows any time with `just`

### Toolchain policy

The workspace has **no MSRV claim** - it deliberately pins a nightly channel.  The pin buys unstable `rustfmt` options and a lint surface that is identical for every contributor and every CI job.  Projects created from this template that want a stable toolchain can change `rust-toolchain.toml` and add an MSRV; nothing in the skeleton crates requires nightly features.

The single source of truth for the required toolchain is **`rust-toolchain.toml`** at the workspace root, which pins a specific known-good nightly channel.  Every dev build and every CI job uses this channel.  See that file's header comment for the bump-cadence history and the upstream-regression notes that keep the pin where it is.

Practical implications for contributors:

- **Don't run `cargo +stable …` against the workspace** while the rustfmt configuration uses unstable options - `cargo +stable fmt` will reject them.
- **Don't add `rust-version = …` to any manifest** while the workspace pins nightly.  A `rust-version` claim next to a nightly pin is noise at best and a false promise at worst.  If your project moves to stable, set MSRV once at the workspace level and let crates inherit it.
- **Bumping the nightly pin** is handled by `just toolchain-sync` (or `just ship-fresh`, which runs `toolchain-sync` as part of the pipeline).  Both update `rust-toolchain.toml` to the latest nightly that compiles the workspace cleanly, and revert if the new channel regresses any gate.

For cross-compilation from macOS/Linux hosts:

- `just setup-cross` - install cross targets used by the workspace
- `just check-cross` - run the CI-style cross-compilation validation
- `just check-windows` - `cargo xwin check` against `x86_64-pc-windows-msvc`

## Preferred validation workflow

Prefer the smallest command that proves your change:

- `just check` - quick workspace validation (`cargo check`, formatting check, file-size policy)
- `just fmt` - format the workspace
- `just test` - workspace tests via nextest/llvm-cov
- `just test-doc` - documentation tests
- `just lint-prod` - strict production Clippy
- `just lint-tests` - test-target Clippy
- `just build` - workspace build
- `just go` - full fast-fail workflow when you want the whole pipeline

Focused examples:

- `cargo nextest run -p acmex-core`
- `cargo test -p acmex-cli -- --nocapture`
- `cargo test -p acmex-version --lib`

## Four-layer quality gates

ACMEX uses a shift-left pipeline: cheap checks fire close to the keystroke, expensive ones move rightward into CI. Each layer is fully opt-in via `just install-hooks` and can be bypassed with `--no-verify` for a single commit or push when you need to.

| Layer | Trigger | Recipe | Budget | What it runs |
|------|--------|--------|--------|-------------|
| **IDE save** | On save | `rust-analyzer` | instant | type-check-on-save, clippy-on-save |
| **pre-commit** | `git commit` | `just lint-fast` | sub-2 s (docs-only) / 15–25 s warm (`*.rs` staged) | `fmt --check`, **`lint-prod`** (ultra-strict: pedantic + nursery + cargo + unwrap_used + missing_docs_in_private_items), **`lint-tests`** (same base + unwrap allowed), **`lint-ci`** (CI-mirror `-D warnings --all-targets`) - all when `*.rs` staged; plus `taplo fmt --check` (if `*.toml` staged), `typos`, `reuse lint`, file-size policy - all in parallel; missing optional tools soft-skip.  Windows xwin lint lives at pre-push, not pre-commit (its cold cost violates the pre-commit budget). |
| **pre-push** | `git push` | `just lint-pre-push` | 25–60 s warm | Same three ultra-strict clippy passes + **Windows `cargo xwin clippy -- -D warnings`** (`lint-ci-windows`) + `fmt --check` + `rustdoc -D warnings` + `cargo deny check` + `nextest run --no-run` (test-binary link check) + file-size policy + `typos` + `reuse lint` - all in parallel.  Full parity with the ship-lane lint surface plus cross-platform Windows clippy coverage; only the full test runtime (`nextest run`) is deferred to CI. |
| **PR CI** | on PR to `main` | `.github/workflows/pr-fast.yml` | minutes | PR-blocking matrix (classify → file-size, drift checks, fmt, sanity, clippy, docs, test-build, tests, security, **windows-lint**, required).  The `classify` job short-circuits docs-only / dep-only / infra-only PRs so heavy jobs only run when code actually changed.  **`windows-lint`** runs `cargo clippy -- -D warnings` natively on `windows-latest` so both `#[cfg(windows)]` compile errors and lint regressions surface at PR time.  The Tier 2 weekly workflow (`.github/workflows/tier-2.yml`) runs coverage + udeps + miri out of the critical path. |
| **Release** | `just ship` / release-plz | `just ship` | minutes | version bump + `release/vX.Y.Z` PR + signed commit + auto-tag + binary build via `release.yml`.  The release lanes are dormant until enabled - see `COMPONENTS.md`. |

The ultra-strict flag stack - `common_flags` / `prod_flags` / `test_flags` - is defined in `just/shared.just` and pulled in identically by the local hooks and by the ship lane, so **the rules a commit is checked against locally are the exact rules CI enforces**.

### Cross-platform coverage

`pr-fast.yml`'s `windows-lint` job runs strict `cargo clippy -- -D warnings` natively on `windows-latest` so both compile errors and lint regressions on `#[cfg(windows)]` paths surface at PR time.  Pre-push runs the cross-compiled equivalent (`just lint-ci-windows`, ~6 s warm) as an advisory local mirror; CI on `windows-latest` is authoritative.  Breakdown:

- **Windows** - `cargo xwin clippy --workspace --all-targets --all-features --no-deps -- -D warnings` via `cargo-xwin` (provisions the MSVC SDK under `~/Library/Caches/xwin/`).  Runs in **~6 s warm** once the SDK is cached.  Wired into pre-push (advisory) and `pr-fast.yml::windows-lint` (authoritative native).
- **Linux** - covered by CI's native `clippy` job on `ubuntu-22.04`.  Two local options for ad-hoc sweeps: **`just lint-ci-linux-zig`** (native macOS → Linux via `cargo-zigbuild`; ~50 s cold / sub-second warm; needs `zig 0.14.1` + `cargo-zigbuild` from `just install-dev-tools`) or **`just lint-ci-linux`** (Docker; mirrors CI's `rust:latest` image exactly; minutes-scale).  Neither runs at pre-push by default.  The zig version is pinned to **0.14.1** - Homebrew's `zig` formula tracks the latest release, which has incompatibility issues with `psm` and `blake3` x86_64 hand-written SIMD assembly, so `install-dev-tools` downloads the tarball from `ziglang.org` instead.
- **macOS / native host** - covered by the three native clippy passes (`lint-ci` / `lint-prod` / `lint-tests`) at both pre-commit and pre-push.

For a full sweep across all three targets, run `just check-all-targets` (native + xwin + zigbuild-or-Docker Linux).  The recipe prefers zigbuild when `zig` is on `PATH`, falls back to Docker, and soft-skips when neither is available.

### First-time setup

```bash
just install-hooks         # sets core.hooksPath → scripts/hooks/
just install-dev-tools     # installs typos-cli + taplo-cli + cargo-xwin + x86_64-pc-windows-msvc target;
                           # on macOS hosts also installs zig 0.14.1 (from ziglang.org - NOT brew) +
                           # cargo-zigbuild + x86_64-unknown-linux-gnu target;
                           # prints pipx hint for `reuse`
```

Re-run `just install-hooks` after any rebase that touches `scripts/hooks/` - it's idempotent.  The first time `cargo xwin clippy` runs it will download the MSVC SDK into `~/Library/Caches/xwin/` (~1–2 GB); subsequent runs reuse the cache.  `zig` lands in `~/.local/zig/0.14.1/` with a symlink in `~/.cargo/bin/zig` so it shadows any `brew install zig` you may have done previously.

### Running gates manually

```bash
just lint-fast             # the pre-commit bundle on demand
just lint-pre-push         # the pre-push bundle on demand
just lint-ci               # the single clippy gate that CI runs (`--all-targets --all-features --no-deps`)
just lint-ci-linux         # same clippy gate under a Linux x86_64 Docker image (authoritative cross-target)
just lint-ci-linux-zig     # same clippy gate via cargo-zigbuild (native macOS → Linux; no Docker; faster)
just check-windows         # cargo xwin check against x86_64-pc-windows-msvc (compile-only fast check)
just lint-ci-windows       # cargo xwin clippy -- -D warnings (matches `pr-fast.yml::windows-lint`)
just check-all-targets     # full sweep: native + Windows (xwin) + Linux (zigbuild or Docker)
just phase1-test           # the full ship-lane Phase-1 validation (pre-ship rehearsal)
```

### Bypass escape hatches

```bash
git commit --no-verify     # skip pre-commit
git push   --no-verify     # skip pre-push
```

Use them for work-in-progress commits on a feature branch. CI will still enforce the same gates on the PR.

### Keeping hook output fast

The hook budgets assume a warm `./target`. An optional user-level sccache setup (see GETTING-STARTED.md § "Performance tuning") speeds cold rebuilds further; if you use one, verify:

- `rustc-wrapper = "sccache"` is set in your own `~/.cargo/config.toml` (the repo config deliberately sets no wrapper).
- `sccache --show-stats` shows a healthy cache-hit rate after a few rebuilds.
- The shared `target/` directory is not being wiped by unrelated tools.

See `scripts/hooks/_lint_fast.sh` and `scripts/hooks/_lint_pre_push.sh` for the shared parallel runners both the hooks and the `just` recipes call into - the hooks are generated from `scripts/ci/gates.toml`, so edit the gate set there and regenerate, not in the hooks themselves.

## Target-dir hygiene

`just test` runs `cargo llvm-cov nextest`, which writes source-instrumented artifacts into `$CARGO_TARGET_DIR/llvm-cov-target/` - a tree that is entirely separate from regular `cargo build`'s `target/debug/` and `target/release/`, and which can grow to **100 GB+** over a long session of coverage runs (each profile bump recompiles everything; every `.profraw` from a failed / killed run stays cached).  On a near-full disk (cloud-sync volume, small SSD, external drive) this is a top cause of otherwise-mysterious disk-pressure test failures.

Run this on the host that surfaced the problem:

```bash
just clean-cov
```

The recipe (`just/cache.just`) prunes:

- `$CARGO_TARGET_DIR/llvm-cov-target/` - the instrumented build tree
- `$CARGO_TARGET_DIR/llvm-cov/` - the HTML coverage report directory
- `$CARGO_TARGET_DIR/**/*.profraw` - leftover instrumentation output from killed / crashed runs
- the per-OS `acmex` local-data scratch directory (orphan files from aborted runs)

It leaves regular `cargo build` artifacts, the sccache wrapper cache, and the Cargo registry alone, so a subsequent `cargo build` stays incremental.

## Commit message conventions

ACMEX uses [Conventional Commits](https://www.conventionalcommits.org/) to drive automated versioning and changelog generation via `release-plz` + `git-cliff`.

**What matters for you**:

- The **PR title** (which becomes the squash-merge commit subject) should follow conventional commits.  Intermediate commits on a feature branch don't need to - only what lands on `main`.
- The local `commit-msg` hook (`scripts/ci/check_commit_subjects.sh`) and the commitlint workflow (`.github/workflows/commitlint.yml`) enforce the convention.

**Recognized types and their release impact**:

| Type | Meaning | Triggers release? | Version bump |
|---|---|---|---|
| `feat:` | User-visible new feature | Yes | Minor (0.X.0) |
| `fix:` | User-visible bug fix | Yes | Patch (0.0.X) |
| `perf:` | Performance improvement | Yes | Patch |
| `feat!:` / `fix!:` | Breaking change (note the `!`) | Yes | Major (X.0.0, or minor pre-1.0) |
| `refactor:` | Code restructure, no behavior change | No | - |
| `docs:` | Documentation only | No | - |
| `test:` | Test additions / changes | No | - |
| `chore:` | Tooling, config, catch-all | No | - |
| `ci:` | CI / workflow change | No | - |
| `build:` | Build system / dependency change | No | - |
| `style:` | Formatting, whitespace | No | - |
| `revert:` | Reverts a previous commit | Inherits reverted type | Inherits |

**Examples**:

- `feat(core): add case-insensitive matching to the greeting engine` - minor bump, appears under "Features" in changelog
- `fix(cli): correct exit code when no arguments are given` - patch bump, appears under "Bug Fixes"
- `feat(cli)!: rename --query to --filter; drop deprecated --q shorthand` - major/minor bump (depending on current v0.x vs v1.x), appears under "BREAKING CHANGES"
- `chore: bump dependabot grouping window to weekly` - no release
- `docs(policies): clarify panic-policy category names` - no release

**Security commits** use the conventional encoding rather than a top-level `security:` type:

- `fix(security): patch hash function for empty inputs` - patch bump, appears under **### Security** in the changelog (the `security` *scope* triggers the dedicated section via `cliff.toml`'s `^fix\(security\)` parser).
- `chore(security): refresh cargo-vet imports` - no bump, also routes to **### Security**.

Top-level `security:` is **not** an allowed type - the local `commit-msg` hook and the commitlint workflow both reject it.

**Scopes** (optional, in parentheses after type): prefer the crate name or a short area tag.  Examples: `core`, `cli`, `version`, `security`, `ci`, `build`, `policies`.  Omit the scope if the change is workspace-wide.

**If in doubt**, use `chore:` - it never triggers a release.  If a PR genuinely has both a fix and a feature, split it into two PRs.

## Architecture guardrails

- Preserve the crate layering: `acmex-version` ← `acmex-core` ← `acmex-cli`.  Library crates never depend on binary crates.
- Prefer fixture-, golden-, or snapshot-based tests for portable validation.
- Update docs when contributor-facing workflow or user-visible behavior changes.
- Any new platform-gated code (`#[cfg(windows)]`, `#[cfg(unix)]`) must pass the full cross-target lint sweep (`just check-all-targets`) before PR - CI's `windows-lint` job enforces the Windows half natively.

## Panic policy

ACMEX enforces a strict no-panic posture in production code via three workspace Clippy lints at `deny` level: `unwrap_used`, `expect_used`, and `panic`.  Test code is exempt (see `clippy.toml` `allow-*-in-tests = true`).

The one-line rule: **library code never panics on user input or environment failure; binaries may panic during bootstrap; every other `panic!` / `unwrap()` / `expect()` in production code is a bug.**

Every surviving prod `unwrap` / `expect` / `panic!` fits exactly one of five categories (A–E), each requiring a specific annotation shape:

- **A** - Invariant violation IS a bug (upstream check guarantees the condition): keep as `expect("invariant: <specific condition>")` plus `#[expect(clippy::expect_used, reason = "<invariant + why upstream check guarantees it>")]`.
- **B** - Caller error / validation failure: convert to typed error variant; propagate via `?`.
- **C** - Environmental (IO, mutex poison, syscall): propagate via `?` after `map_err` to a typed error, preserving the source via `#[from]` or `#[source]`.
- **D** - Bootstrap (one-time process startup, crash-correct): keep as `expect("BOOT INVARIANT: <condition>")` with `#[expect(...)]`.
- **E** - Programmer bug at use site: keep as `panic!` with documented invariant in the enclosing function's `# Panics` doc section.

Full taxonomy, anti-patterns, per-crate posture, and the per-site annotation contract live in [`docs/policies/panic_policy.md`](docs/policies/panic_policy.md).  Library crates do not return `anyhow::Error` from public APIs and do not return `Result<_, String>` (banned workspace-wide); use a typed `thiserror::Error` enum with `#[non_exhaustive]` instead.

## Allocation policy

ACMEX enforces a strict clone-and-allocation discipline in production code via five workspace Clippy lints at `deny` level: `redundant_clone`, `clone_on_ref_ptr`, `cloned_instead_of_copied`, `inefficient_to_string`, and `unnecessary_to_owned`.  Test code is exempt.

The one-line rule: **hot paths (per-record / per-row / per-query) never allocate defensively; cold paths (error context, log lines, one-time setup) may allocate freely; every `.clone()` / `format!()` / `to_owned()` in production code must fit one of the five blessed categories (α / β / γ / δ / ε), and δ is a bug.**

Every surviving prod `.clone()` / `format!()` / `to_owned()` fits exactly one of five categories, each requiring a specific annotation shape:

- **α - Arc clone** (`Arc::clone(&x)` form): self-evident; no comment required.  `clone_on_ref_ptr = "deny"` enforces the explicit form.
- **β - Ownership fence** (caller has `&T`, API needs `T`): 1–3 line `//` comment explaining why the alternative (`&T`, in-place mutation) doesn't work.
- **γ - Error / log context** (allocation inside an error variant or `tracing!` event): brief reason; the *category* is self-evident from the context.
- **δ - Hot-path anti-pattern** (clone of `String` / `Vec<T>` inside a per-record loop that could be eliminated): **FIX, do not suppress.**  Refactor the call site with a comment documenting the new (correct) borrow invariant.
- **ε - Test helper** (`#[cfg(test)]`-only allocation): out of scope; test code is exempt.

Full taxonomy and the per-site annotation contract live in [`docs/policies/allocation_policy.md`](docs/policies/allocation_policy.md).

## Trait, generic, and dispatch policy

ACMEX enforces a strict trait / generic / dispatch discipline in production code via five workspace Clippy lints: `type_complexity`, `too_many_arguments`, `trait_duplication_in_bounds`, `wrong_self_convention` (all `deny`), and `multiple_bound_locations` (`warn`).  Test code is exempt.

The one-line rule: **a trait must satisfy at least one of [J1] multiple impls / [J2] test substitution / [J3] stable extension / [J4] high-level decoupling - otherwise it's decoration.  Generics stay local.  `dyn` for plugin boundaries; static for closed sets.**

Trait justification four-criterion taxonomy:

- **[J1]** Multiple meaningful implementations (≥ 2 prod impls on `main`).
- **[J2]** Test-substitution boundary (prod impl + ≥ 1 test fake).
- **[J3]** Stable extension surface (rustdoc documents external impls).
- **[J4]** High-level / infrastructure decoupling.

A trait satisfying **none** of J1–J4 → demote to a concrete type and replace usages.

Generic-function categories (G1-LOCAL / G2-USEFUL / G3-SPREAD / G4-CASCADING / G5-CLOSURE), the dispatch matrix (D1-PLUGIN / D2-HETERO / D3-NOOP / D4-VTBL-COST), and the seal-vs-open decision tree live in [`docs/policies/trait_policy.md`](docs/policies/trait_policy.md).

## Feature flag and dependency policy

ACMEX keeps feature behavior additive and dependency duplication audited.  No new clippy lints; the contract is enforced by `cargo deny check`, `cargo machete`, `cargo vet`, and `cargo tree --workspace -d`, all wired into pre-push and `pr-fast.yml::security`.

The one-line rule: **every feature is additive (enabling never removes a `pub` item); every default has a written justification; every optional dep is reachable via `dep:<name>` and at least one `#[cfg(feature = "…")]` use-site; every cross-version duplicate is either in `deny.toml [bans].skip-tree` with a one-line reason or accepted by the workspace's `multiple-versions = "warn"` posture and inventoried in `dependency_policy.md` §5.1.**

Every feature added to the workspace must document the four-line contract in **both** the crate's root rustdoc (`# Features` section) and as a block comment above the `[features]` block in `Cargo.toml`:

- **What it enables** - which module / item / subcommand / binary.
- **What deps it adds** - `dep:<name>` gating + transitive feature pulls.
- **API shape impact** - additive (default) | subtractive (forbidden).
- **Semver claim** - adding items behind it is non-breaking; removing items behind it is breaking.

The feature taxonomy (F1-additive-default-on / F2-additive-default-off / F3-orthogonal / F4-subtractive-FORBIDDEN / F5-feature-on-feature) and the cross-version duplicate acceptance inventory live in [`docs/policies/dependency_policy.md`](docs/policies/dependency_policy.md).

## Build, codegen, and env-var policy

ACMEX keeps compile-time magic justified and traceable.  No new clippy lints; the contract is enforced by the `gates-drift` / `hooks-drift` / `fast-drift` / `workflow-drift` / `manifest-drift` gates wired into pre-push and `pr-fast.yml`.

The one-line rule: **every `build.rs` falls into one of the three justification classes; every `macro_rules!` falls into one of the three justification classes (control-flow hiding is forbidden); every codegen binary has a drift detector or a documented "no idempotency contract" rationale; every environment variable the workspace reads is registered in `build_codegen_policy.md` §5 with name, scope, type, default, where read, and semver class.**

Current template posture:

- **5 `build.rs` files** - `acmex-cli` plus the four CI tool crates, all doing the same one thing: stamping git sha + build metadata via `acmex_version::emit_build_env()`.
- **0 proc-macro crates** - deliberate workspace posture; introducing one requires unanimous review.
- **0 `macro_rules!` declarations** in the skeleton crates.
- **3 codegen binaries** - `acmex-gen-hooks`, `acmex-gen-workflow` (emitter/validators, drift-detected) and `acmex-manifest-audit` (auditor), all under `scripts/ci/`.

The `build.rs` / proc-macro / `macro_rules!` / codegen / env-var per-class contracts and the env-var registry live in [`docs/policies/build_codegen_policy.md`](docs/policies/build_codegen_policy.md).

## Concurrency policy

ACMEX enforces a strict task-ownership, lock-discipline, channel-backpressure, timeout-coverage, and blocking-IO posture in production async code.  Three workspace Clippy lints at `deny` cover the std-side lock-across-await family (`await_holding_lock`, `await_holding_refcell_ref`, `await_holding_invalid_type`); the rest is enforced by a per-site annotation contract.  The skeleton crates are synchronous today; the policy binds the moment async code lands.

The one-line rule: **every `tokio::spawn` declares its owner / shutdown / errors / cancellation; every async lock guard is dropped before the next `.await`; every channel is bounded with documented capacity OR unbounded with a documented producer-rate ceiling; every cross-process / cross-thread / cross-network await has a timeout OR is justified as a cooperatively-cancelled forever-loop; every `std::fs::*` / `std::thread::sleep` inside an `async fn` is wrapped in `spawn_blocking` / `block_in_place` OR is a sync helper called only from sync contexts.**

Five dimensions, each with a taxonomy contributors quote inline:

- **Task ownership** (`T1` named-constructor / `T2` inline-spawn / `T3` fire-and-forget / `T4` test-only) - every prod spawn site documents the four facets above.
- **Lock discipline** (`L1`-`L5` patterns; `L6` lock-across-await is forbidden) - three Clippy `await_holding_*` lints at `deny`.
- **Channel discipline** (`C1` bounded / `C2` broadcast / `C3` oneshot / `C4` watch / `C5` unbounded-with-ceiling; `C6` undocumented unbounded is forbidden).
- **Timeout policy** (`W1` named const / `W2` env-overridable / `W3` cooperatively-cancelled forever-loop / `W4` inline literal; `W5` unbounded cross-process await is forbidden).
- **Blocking-IO rule** (`B1` `spawn_blocking` / `B2` `block_in_place` / `B3` sync helper / `B4` startup/Drop/CLI one-shot; `B5` unbounded sync I/O on runtime worker is forbidden).

Full taxonomy and per-site annotation templates live in [`docs/policies/concurrency_policy.md`](docs/policies/concurrency_policy.md).

## Docs map

- Root overview: `README.md`
- Growth catalog (dormant lanes, add-a-component recipes): `COMPONENTS.md`
- Policy docs (lint posture, panic, allocation, trait, dependency, build/codegen, concurrency): `docs/policies/`
- Security policy: `SECURITY.md`
- Trademark policy (template placeholder): `TRADEMARK.md`
