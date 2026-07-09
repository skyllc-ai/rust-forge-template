// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

#![expect(
    clippy::print_stdout,
    reason = "operational CLI tool — phase banners + step results go to stdout (issue #212)"
)]

//! Non-resumable Phase 1 / Phase 2 driver functions.
//!
//! These variants skip the [`crate::workflow::WorkflowState`] wrapper
//! and run straight through from start to finish.  They back the
//! standalone `just go`, `just check-all`, and `just phase2-ship`
//! recipes — i.e. the lanes where "resume mid-flight" semantics are
//! not useful because the lane has no state to preserve.  The
//! resumable equivalents live in [`crate::ship`].
//!
//! * [`phase1_optimized`] — thin orchestrator: [`phase1_prime`] →
//!   [`phase1_tests`] → [`phase1_fanout_validation`].
//! * [`phase2_optimized`] — commit + push in a straight line (used by `just
//!   phase2-ship`, separate from the resumable `run_enhanced_phase2` that
//!   [`crate::ship`] drives). Version bumping is handled by release-plz on
//!   `main`.
//! * [`coverage_data_exists`] / [`coverage_report_command`] — the
//!   `coverage-report` subcommand primitives; referenced from both
//!   `phase1_tests` and the CLI dispatch.

use anyhow::{Context as _, Result};
use colored::Colorize as _;

use crate::context::{PipelineContext, get_cargo_target_dir};
use crate::exec::{execute_command, execute_parallel_with_env};
use crate::git_ops::{git_commit, git_push};
use crate::version::get_current_version;
use crate::workflow::WorkflowState;

/// Return `true` if a previous `cargo llvm-cov` run left behind
/// coverage data under `target/llvm-cov-target/` — the signal
/// `coverage-report` uses to decide whether to regenerate HTML from
/// cached data or re-run the whole test suite with instrumentation.
pub(crate) fn coverage_data_exists() -> bool {
    let target_dir = get_cargo_target_dir();
    target_dir.join("llvm-cov").exists()
}

/// Entry point for the `coverage-report` subcommand: regenerates the
/// HTML coverage report from existing instrumentation data, or runs
/// the full coverage test pass first if the data is missing.
///
/// # Errors
///
/// Propagates any failure from the wrapped `cargo llvm-cov` / `cargo
/// llvm-cov nextest` subprocesses.
pub(crate) async fn coverage_report_command(ctx: &PipelineContext) -> Result<()> {
    println!("{}", "📊 Coverage Report Generation".blue().bold());
    if coverage_data_exists() {
        println!(
            "{} Found existing coverage data, generating report...",
            "🔍".green()
        );
        execute_command(
            "Coverage report",
            "cargo",
            &["llvm-cov", "report", "--html"],
            ctx,
        )
        .await?;
    } else {
        println!(
            "{} No coverage data found, running tests first...",
            "⚠️".yellow()
        );
        execute_command(
            "Coverage tests",
            "cargo",
            &[
                "llvm-cov",
                "nextest",
                "--workspace",
                "--all-features",
                "--lib",
                "--bins",
                "--tests",
                "--profile",
                "ci",
                "--html",
            ],
            ctx,
        )
        .await?;
    }
    println!(
        "{} Coverage report: target/llvm-cov/html/index.html",
        "📁".green()
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1 (non-resumable)
// ─────────────────────────────────────────────────────────────────────────────

/// Prime the workspace before the heavy validation stages: ensure the
/// pinned nightly is installed and run the file-size policy (which
/// catches structural repo violations before any compilation cost).
async fn phase1_prime(ctx: &PipelineContext) -> Result<()> {
    execute_command("Toolchain ensure", "just", &["toolchain-ensure"], ctx).await?;
    execute_command(
        "File size policy",
        "bash",
        &["scripts/ci/check_file_size_policy.sh"],
        ctx,
    )
    .await
}

/// Run the workspace nextest test pass, then optionally regenerate the
/// HTML coverage report when `--coverage-report` is in effect.
async fn phase1_tests(ctx: &PipelineContext) -> Result<()> {
    execute_command(
        "Workspace tests",
        "cargo",
        &[
            "nextest",
            "run",
            "--workspace",
            "--all-features",
            "--lib",
            "--tests",
            "--profile",
            "ci",
        ],
        ctx,
    )
    .await?;

    if ctx.flags.coverage_report {
        coverage_report_command(ctx).await
    } else {
        if ctx.flags.verbose {
            println!(
                "{} Coverage report skipped (use --coverage-report to generate)",
                "⏭️".yellow()
            );
        }
        Ok(())
    }
}

/// Fan out the Phase 1 validation stack (doctests + production clippy +
/// test clippy + `cargo deny` + rustdoc link validation) with
/// `RUSTDOCFLAGS=-Dwarnings` so rustdoc failures are hard errors.
///
/// Kept as data + one call so that any future lint-profile churn lands
/// in exactly one place.
async fn phase1_fanout_validation(ctx: &PipelineContext) -> Result<()> {
    let parallel_commands = vec![
        ("Documentation tests", "cargo", vec![
            "test",
            "--doc",
            "--workspace",
            "--all-features",
        ]),
        // pedantic/nursery/cargo/multiple_crate_versions levels are set
        // in workspace Cargo.toml — only per-target overrides needed
        // here.
        ("Production linting", "cargo", vec![
            "clippy",
            "--workspace",
            "--all-targets",
            "--all-features",
            "--no-deps",
            "--",
            "-D",
            "warnings",
            "-W",
            "clippy::panic",
            "-W",
            "clippy::todo",
            "-W",
            "clippy::unimplemented",
            "-W",
            "clippy::unwrap_used",
            "-W",
            "clippy::expect_used",
        ]),
        ("Test linting", "cargo", vec![
            "clippy",
            "--workspace",
            "--all-targets",
            "--all-features",
            "--tests",
            "--no-deps",
            "--",
            "-D",
            "warnings",
            "-W",
            "clippy::panic",
            "-W",
            "clippy::todo",
            "-W",
            "clippy::unimplemented",
            "-A",
            "clippy::unwrap_used",
            "-A",
            "clippy::expect_used",
        ]),
        ("Dependency security", "cargo", vec!["deny", "check"]),
        // WI-G.1 regression gate: fail if any "Bugs Rust Won't Catch"
        // anti-pattern (lossy UTF decode feeding a decision, predictable temp,
        // perms-after-create on a secret, discarded control-channel write, …)
        // is reintroduced into production code. Wired in here (now that the
        // gate is green) so `just go` / the ship lane enforce it alongside the
        // clippy trio + cargo-deny.
        ("Anti-pattern gate", "bash", vec![
            "scripts/ci/anti_pattern_gate.sh",
        ]),
        // `--document-private-items` is REQUIRED to validate links across the
        // private surface (`pub(crate)` items, `//!` shortcuts to private
        // siblings); without it rustdoc only checks the public API and a broken
        // link silently renders as dead text. Mirrors `just rustdoc`.
        ("Rustdoc link validation", "cargo", vec![
            "doc",
            "--workspace",
            "--all-features",
            "--no-deps",
            "--document-private-items",
        ]),
    ];
    execute_parallel_with_env(parallel_commands, &[("RUSTDOCFLAGS", "-Dwarnings")], ctx).await
}

/// Phase 1: Safe-by-default validation with maximum parallelism.
///
/// Thin orchestrator: [`phase1_prime`] (toolchain + file-size policy)
/// → [`phase1_tests`] (workspace nextest + optional coverage) →
/// [`phase1_fanout_validation`] (doctests + clippy trio + deny +
/// rustdoc).
///
/// # Errors
///
/// Propagates any failure from the three sub-stages.
pub(crate) async fn phase1_optimized(ctx: &PipelineContext) -> Result<()> {
    println!(
        "{}",
        "🧪 PHASE 1: Safe-by-Default Validation Pipeline"
            .blue()
            .bold()
    );
    println!("ℹ️  No version bump, deploy, commit, or push in this lane");

    phase1_prime(ctx).await?;
    phase1_tests(ctx).await?;
    phase1_fanout_validation(ctx).await?;

    println!(
        "{}",
        "✅ PHASE 1 COMPLETE: Validation passed without release-side effects!"
            .green()
            .bold()
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 (explicit ship lane — non-resumable counterpart)
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 2: Explicit ship lane (commit → push).  Used by the
/// standalone `just phase2-ship` recipe.  The resumable equivalent
/// lives in [`crate::ship::run_enhanced_phase2`] and is the one
/// `run_ship_pipeline` calls.
///
/// # Errors
///
/// Propagates any failure from [`git_commit`] or [`git_push`].
/// The workflow-state mutation will also fail if the state file
/// cannot be written.
pub(crate) async fn phase2_optimized(ctx: &PipelineContext) -> Result<()> {
    println!("{}", "🚀 PHASE 2: Explicit Ship Lane".blue().bold());

    // Note: Version increment retired in Phase R5. release-plz now
    // handles version bumps automatically on `main` after PR merge.

    // Update workflow state with current version
    let mut state = WorkflowState::load().context("Failed to load workflow state")?;
    let current_version = get_current_version().context("Failed to get current version")?;
    state.current_version = current_version;
    state.save().context("Failed to save workflow state")?;
    println!(
        "✅ Workflow state initialized with version: {}",
        state.current_version
    );

    // Step 1: Git commit (signed commit on the working branch).
    git_commit(ctx).await?;

    // Step 2: Git push -- opens release/vX.Y.Z PR with auto-merge
    // queued.
    //
    // Binaries are NOT built here.  Once the PR merges to main,
    // release-plz tags the commit and invokes `release.yml`, which
    // produces the reproducible cross-platform binaries on GitHub-hosted
    // runners.
    git_push(ctx).await?;

    println!(
        "{}",
        "✅ PHASE 2 COMPLETE: Committed and release PR opened (version via release-plz)!"
            .green()
            .bold()
    );
    Ok(())
}
