// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

//! Version discovery helpers for the ACMEX ship pipeline.
//!
//! * [`get_current_version`] — read `[workspace.package].version` out of the
//!   root `Cargo.toml` (simple whole-file scan).
//! * [`extract_version_from_cargo_toml`] — same, but strict: only considers the
//!   `[workspace.package]` section.

use anyhow::{Context as _, Result, bail};

/// Read the workspace root `Cargo.toml` and return the first
/// `version = "..."` string found.  Used by the push step to build
/// `origin/release/vX.Y.Z`.
///
/// # Errors
///
/// Returns an error if `Cargo.toml` cannot be read, or if no `version`
/// line is present.
pub(crate) fn get_current_version() -> Result<String> {
    let cargo_toml = std::fs::read_to_string("Cargo.toml").context("Failed to read Cargo.toml")?;
    for line in cargo_toml.lines() {
        if line.trim().starts_with("version = ")
            && let Some(version) = line.split('"').nth(1)
        {
            return Ok(version.to_owned());
        }
    }
    bail!("Could not find version in Cargo.toml")
}

/// Bump the lockstep `[workspace.package].version` (plus the internal
/// `[workspace.dependencies]` version requirements and the lockfile) by
/// `level` — `"patch"`, `"minor"`, or `"major"` — via `cargo set-version`.
///
/// This restores the Phase-2 version-increment step retired in R5.  It shells
/// out to `cargo-edit`'s `set-version` rather than re-implementing semver math
/// (the ~1430 LOC R5 deleted): `set-version` already handles workspace
/// inheritance and the internal dep-requirement updates correctly.  `just ship`
/// is a maintainer-only release command, so requiring `cargo-edit` on the
/// release machine is acceptable.
///
/// # Errors
///
/// Returns an error if `cargo set-version` is not installed or the bump fails.
pub(crate) fn bump_workspace_version(level: &str) -> Result<()> {
    let available = std::process::Command::new("cargo")
        .args(["set-version", "--help"])
        .output()
        .is_ok_and(|out| out.status.success());
    if !available {
        bail!(
            "`cargo set-version` not found — install it with `cargo install cargo-edit` \
             (required by `just ship` to bump the release version)."
        );
    }
    let status = std::process::Command::new("cargo")
        .args(["set-version", "--bump", level])
        .status()
        .context("running `cargo set-version`")?;
    if !status.success() {
        bail!("`cargo set-version --bump {level}` failed");
    }
    // Refresh the lockfile so the release commit is byte-reproducible.
    std::process::Command::new("cargo")
        .args(["update", "--workspace", "--quiet"])
        .status()
        .context("refreshing Cargo.lock after version bump")?;
    Ok(())
}

/// Parse `content` (the text of a workspace root `Cargo.toml`) and
/// extract the `version = "..."` entry from the `[workspace.package]`
/// table specifically — ignores any unrelated `version = ...` lines in
/// `[dependencies]` or per-crate overrides.
///
/// # Errors
///
/// Returns an error if `[workspace.package]` is missing, or if it does
/// not contain a parseable `version` entry.
pub(crate) fn extract_version_from_cargo_toml(content: &str) -> Result<String> {
    let mut in_workspace_package = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "[workspace.package]" {
            in_workspace_package = true;
            continue;
        }
        if in_workspace_package {
            if trimmed.starts_with('[') && trimmed != "[workspace.package]" {
                break;
            }
            if trimmed.starts_with("version")
                && let Some((_, after_eq)) = trimmed.split_once('=')
            {
                let version = after_eq.trim().trim_matches('"').trim_matches('\'');
                return Ok(version.to_owned());
            }
        }
    }
    bail!("Version extraction failed - no version found in [workspace.package]")
}
