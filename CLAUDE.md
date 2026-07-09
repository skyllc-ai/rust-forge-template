# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

acmex is a template-placeholder Rust workspace (created from rust-forge-template).
Replace this section with the real project description after `just init`.

## Build & Development Commands

The primary workflow tool is `just` (justfile). Use `just` to see all commands.

```bash
# Safe-by-default validation (no version bump / deploy / commit / push)
just go

# Explicit ship lane (version bump / changelog / release PR / auto-merge)
just ship

# Quick check during development
just check

# Format code (rustfmt only)
just fmt

# Run all tests with nextest
just test

# Run a single test or test filter
cargo nextest run -p acmex-core -- greeting

# Lint production code (ultra-strict)
just lint-prod

# Lint test code (allows unwrap/expect)
just lint-tests

# Security audit
just audit

# One-time setup: toolchain + gate tools + git hooks + smoke check
just setup
```

## Architecture

Cargo workspace:

```
crates/
├── acmex-core/      Core library (placeholder greeting logic — replace me)
├── acmex-cli/       CLI binary `acmex` (clap; placeholder — replace me)
└── acmex-version/   Shared --version machinery (version_short!/version_long!/
                     handle_version! macros + build.rs env stamping)
scripts/
├── ci-pipeline/     acmex-ci-pipeline: the `just go`/`just ship` driver
│                    (resumable state machine, parallel gate fan-out)
└── ci/              gates.toml (single source of truth for all quality gates)
                     + acmex-gen-hooks (emits pre-commit/pre-push hooks)
                     + acmex-gen-workflow (validates pr-fast.yml vs gates.toml)
                     + acmex-manifest-audit (15 manifest-inheritance invariants)
```

## Key conventions

- **Never edit `scripts/hooks/_lint_fast.sh` / `_lint_pre_push.sh` by hand** —
  they are generated from `scripts/ci/gates.toml` by `acmex-gen-hooks`; edit
  the manifest and run `just acmex-gen-hooks` (drift gates enforce this).
- **Never bypass gates** (`--no-verify` is blocked by a Claude Code hook);
  fix the failing gate at its root.
- Every crate manifest inherits everything from the workspace
  (`*.workspace = true`, `[lints] workspace = true`); `acmex-manifest-audit`
  enforces this.
- Dormant capability lanes (crates.io, winget, release, SLSA) are switched on
  via data changes only — see `COMPONENTS.md`.

## Linting Standards

The workspace enforces extremely strict Clippy settings in `Cargo.toml` `[workspace.lints]`:
- `unwrap_used`, `expect_used`, `panic`, `todo`, `unimplemented`, `unreachable` are all **denied**
- All code must be documented (`missing_docs_in_private_items = "deny"`)
- `unsafe_code = "deny"` at the Rust lint level
- `allow` attributes are denied — use `#[expect(..., reason = "...")]`
- Test code gets relaxed rules via `just lint-tests` (allows `unwrap`/`expect`)

## Testing Notes

- Unit tests live in `#[cfg(test)] mod tests` blocks; integration tests in
  `crates/<crate>/tests/` wrapped in `#[cfg(test)] mod tests`
- Prefer focused fixture, golden-output, or regression tests
- Platform- or resource-gated tests are `#[ignore]` — run with
  `cargo nextest run --profile slow --run-ignored ignored-only`
- nextest profiles: `default` (local), `ci`, `pre-push-smoke`, `slow`
  (`.config/nextest.toml`)
