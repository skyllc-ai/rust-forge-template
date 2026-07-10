// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

#![expect(
    clippy::print_stdout,
    reason = "operational CLI tool - progress + summary lines go to stdout (issue #212)"
)]

//! Cross-compilation syntax validation for the `cross-check`
//! subcommand.  Runs native-tooling Linux + Windows `cargo check`
//! passes, skipping each half gracefully if the corresponding tool-
//! chain is missing (so a laptop without `x86_64-linux-gnu-gcc` or
//! `cargo-xwin` can still call `just check-cross` without a fatal
//! error).

use anyhow::{Context as _, Result};

use crate::context::PipelineContext;
use crate::exec::execute_command;

/// `cross-check` subcommand: run native-tooling Linux + Windows cross-
/// compilation syntax checks, skipping each half gracefully if the
/// corresponding toolchain is missing.
///
/// # Errors
///
/// Propagates any failure from the inner `cargo check` / `cargo xwin
/// check` subprocesses.  Toolchain absence is informational (not an
/// error) so operators can still drive this from a laptop without
/// the cross-build tooling installed.
pub(crate) async fn handle_cross_check(ctx: &PipelineContext) -> Result<()> {
    println!("🔍 Cross-compilation syntax validation...");
    println!("⚠️  Note: This checks syntax only (no linking) to catch API compatibility issues");

    // Linux x86_64 via system gcc cross-toolchain.
    let has_cross_toolchain = std::process::Command::new("which")
        .arg("x86_64-linux-gnu-gcc")
        .output()
        .is_ok_and(|output| output.status.success());

    if has_cross_toolchain {
        execute_command(
            "Cross-compile syntax check (Linux x86_64)",
            "cargo",
            &[
                "check",
                "--workspace",
                "--all-features",
                "--target",
                "x86_64-unknown-linux-gnu",
                "--lib",
            ],
            ctx,
        )
        .await
        .context("Cross-compilation syntax check failed")?;
        println!("✅ Cross-compilation syntax check passed");
    } else {
        println!("⚠️  Cross-compilation toolchain not available (x86_64-linux-gnu-gcc)");
        println!("   This check will run in CI with proper toolchain setup");
        println!("✅ Cross-compilation setup completed (skipped locally)");
    }

    // Windows x86_64 via cargo-xwin (bundles MSVC headers/libs).
    let has_cargo_xwin = std::process::Command::new("cargo")
        .args(["xwin", "--version"])
        .output()
        .is_ok_and(|output| output.status.success());

    if has_cargo_xwin {
        execute_command(
            "Cross-compile syntax check (Windows x86_64)",
            "cargo",
            &[
                "xwin",
                "check",
                "--workspace",
                "--target",
                "x86_64-pc-windows-msvc",
            ],
            ctx,
        )
        .await
        .context("Windows cross-compilation syntax check failed")?;
        println!("✅ Windows cross-compilation syntax check passed");
    } else {
        println!("⚠️  cargo-xwin not available - skipping Windows cross-check");
        println!("   Install with: cargo install cargo-xwin");
    }
    Ok(())
}
