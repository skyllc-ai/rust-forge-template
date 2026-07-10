// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.
//
//! Runtime context for the ACMEX CI pipeline.
//!
//! [`PipelineContext`] is the "everything-every-step-reads" struct:
//! it carries wall-clock timers, resource-limit config, env overrides,
//! the log-file sink, and the resolved [`PipelineFlags`].
//!
//! The boolean flags are extracted into [`PipelineFlags`] so the
//! outer context struct stays under clippy's `struct_excessive_bools`
//! threshold - see that struct's doc comment for the rationale.
//!
//! This module also owns the small filesystem helpers the context
//! construction needs (`get_cargo_target_dir`, `sccache_is_functional`,
//! `disk_free_bytes`, `dir_size_bytes`).

use core::time::Duration;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;

use tokio::process::Command;
use tokio::time::timeout;

use crate::cli::Cli;

// ─────────────────────────────────────────────────────────────────────────────
// Path / env helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve the effective `CARGO_TARGET_DIR`, checking the env var first,
/// then `.cargo/config.toml`, and finally falling back to `./target`.
pub(crate) fn get_cargo_target_dir() -> PathBuf {
    if let Ok(target_dir) = std::env::var("CARGO_TARGET_DIR") {
        return expand_tilde_path(&target_dir);
    }
    if let Some(target_dir) = parse_cargo_config_target_dir() {
        return target_dir;
    }
    PathBuf::from("./target")
}

/// Expand a leading `~` to the current user's home directory on Unix-
/// like hosts.  Returns the input unchanged on Windows or when `$HOME`
/// is unset.
fn expand_tilde_path(path_str: &str) -> PathBuf {
    if (path_str == "~" || path_str.starts_with("~/"))
        && let Ok(home) = std::env::var("HOME")
    {
        let rest = path_str.strip_prefix("~/").unwrap_or("");
        return PathBuf::from(home).join(rest);
    }

    PathBuf::from(path_str)
}

/// Parse `.cargo/config.toml` for a `target-dir = "..."` entry.
/// Returns `None` if the file is absent or the entry is missing.
fn parse_cargo_config_target_dir() -> Option<PathBuf> {
    let config_path = ".cargo/config.toml";
    if let Ok(content) = fs::read_to_string(config_path) {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("target-dir")
                && let Some(value) = trimmed.split('=').nth(1)
            {
                let path_str = value.trim().trim_matches('"').trim_matches('\'');
                return Some(expand_tilde_path(path_str));
            }
        }
    }
    None
}

/// Return `true` if sccache can successfully wrap a rustc invocation.
///
/// `which sccache` is not enough: on some hosts the binary is present
/// but the daemon fails to start (sandbox, missing IPC socket, etc.),
/// causing every cargo invocation that inherits `RUSTC_WRAPPER=sccache`
/// to die with "Operation not permitted".  Running `sccache rustc -vV`
/// - the exact call Cargo makes for every build - flushes that out.
///
/// Note that this probe is not perfect: on some macOS shells sccache
/// can succeed at the top level yet still fail when invoked as a
/// nested subprocess of `cargo`.  Steps that are known to trip that
/// (e.g. `cargo clean`, see `ship.rs`) explicitly clear `RUSTC_WRAPPER`
/// for themselves rather than relying on this probe.
pub(crate) fn sccache_is_functional() -> bool {
    std::process::Command::new("sccache")
        .args(["rustc", "-vV"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .is_ok_and(|out| out.status.success())
}

/// Capture a stable identity string for the currently active `rustc`.
///
/// Runs `rustc -vV`, whose output lists the release, commit-hash,
/// commit-date, host triple, and LLVM version - a tuple that changes on
/// every nightly bump.  The clean step uses this as a fingerprint: when
/// the active toolchain differs from the one that built the cached
/// `target` dir, Cargo's rustc-version-specific cross-crate metadata is
/// invalid (every build explodes with `E0514` "found crate compiled by
/// a different version of rustc") and a `cargo clean` must be forced.
///
/// `RUSTC_WRAPPER` is cleared for the probe so it never routes through
/// sccache, which can fail in nested subprocesses on some macOS hosts
/// (see [`sccache_is_functional`]).
///
/// Returns `None` when `rustc` cannot be spawned or exits non-zero; the
/// caller then treats the toolchain as unknown and falls back to the
/// disk-pressure auto-clean policy.
pub(crate) fn active_rustc_id() -> Option<String> {
    let output = std::process::Command::new("rustc")
        .args(["-vV"])
        .env("RUSTC_WRAPPER", "")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let id = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!id.is_empty()).then_some(id)
}

// ─────────────────────────────────────────────────────────────────────────────
// Disk-pressure helpers (used by the Phase 1 auto-clean step)
// ─────────────────────────────────────────────────────────────────────────────

/// Convert bytes to GiB (binary).
pub(crate) const fn bytes_to_gib(bytes: u64) -> u64 {
    bytes / 1024 / 1024 / 1024
}

/// Best-effort free-space lookup for the filesystem containing `path`.
/// Returns the available bytes, or `None` when the query is not
/// supported on the host (Windows) or the underlying `df` invocation
/// fails.  Uses `df -Pk` on unix-y systems.
pub(crate) async fn disk_free_bytes(path: &Path) -> Option<u64> {
    if cfg!(windows) {
        return None;
    }
    let path_str = path.to_str()?;
    let output = Command::new("df")
        .arg("-Pk")
        .arg(path_str)
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut lines = stdout.lines();
    lines.next()?; // header
    let last = lines.last()?;
    // `df -Pk` line format: `Filesystem 1024-blocks Used Available Capacity
    // Mounted-on`. Use the iterator API instead of byte-indexing so a malformed
    // `df` output yields `None` rather than panicking via `cols[3]`.
    let avail_k = last.split_whitespace().nth(3)?.parse::<u64>().ok()?;
    Some(avail_k * 1024)
}

/// Best-effort directory size for `path`, in bytes.  Uses `du -sk` on
/// unix-y systems and is time-limited via `timeout_dur` so a pathological
/// walk cannot stall the pipeline.
pub(crate) async fn dir_size_bytes(path: &Path, timeout_dur: Duration) -> Option<u64> {
    if cfg!(windows) {
        return None;
    }
    let path_str = path.to_str()?;

    let child = Command::new("du")
        .arg("-sk")
        .arg(path_str)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let Ok(Ok(output)) = timeout(timeout_dur, child.wait_with_output()).await else {
        return None;
    };

    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let kb = stdout.split_whitespace().next()?.parse::<u64>().ok()?;
    Some(kb * 1024)
}

// ─────────────────────────────────────────────────────────────────────────────
// PipelineContext + PipelineFlags
// ─────────────────────────────────────────────────────────────────────────────

/// Pipeline execution context with resource management.
///
/// All runtime boolean flags live in [`PipelineFlags`] (see that struct
/// for why they are grouped); the fields on `PipelineContext` proper
/// are non-flag runtime state (timers, paths, job counts, env).
pub(crate) struct PipelineContext {
    /// Wall-clock start of the pipeline run; used to report total duration.
    pub start_time: Instant,
    /// Hard upper bound on simultaneous `cargo` invocations during the
    /// fan-out validation stage.  Kept separate from `max_parallel_jobs`
    /// so we don't multiply rustc threads × fan-out and OOM the host.
    /// Defaults to `max(num_cpus / 4, 2)` when `--jobs` is not set;
    /// when `--jobs N` is explicit it clamps to `min(N, max_parallel_jobs)`.
    pub fanout_concurrency: usize,
    /// Per-step command timeout.  Applied uniformly to every subprocess.
    pub timeout_duration: Duration,
    /// Runtime boolean flags (CLI-derived + sccache auto-detection).
    pub flags: PipelineFlags,
    /// Auto-clean threshold: free disk space in GiB below which the run
    /// pre-emptively invokes `cargo clean`.
    pub min_free_gb: u64,
    /// Auto-clean threshold: target-dir size in GiB above which the run
    /// pre-emptively invokes `cargo clean`.  Unix-only; best-effort.
    pub max_target_gb: u64,
    /// Global environment variables to set for all cargo commands.
    pub global_env: Vec<(String, String)>,
    /// Log file for capturing output in non-verbose mode.
    pub log_file: Option<PathBuf>,
}

/// Boolean-only subset of [`PipelineContext`]: every `Cli` flag the
/// pipeline threads through its step functions, plus the derived sccache
/// auto-detection result.
///
/// Lives in its own struct because clippy's `struct_excessive_bools`
/// fires on any struct with more than three booleans - and the natural
/// mitigation for a flags container is *more* flags, not fewer.
/// Isolating them here keeps [`PipelineContext`] itself clean and lets
/// the scoped `#[expect]` attach to its actual target (a flags bag,
/// for which the lint's "consider refactoring" hint does not apply).
#[expect(
    clippy::struct_excessive_bools,
    reason = "dedicated flags container; grouping IS the design, not a workaround"
)]
#[derive(Debug, Clone, Copy)]
pub(crate) struct PipelineFlags {
    /// Echo full command lines and captured stdout/stderr to the terminal.
    pub verbose: bool,
    /// Generate an HTML coverage report after the test stage.
    pub coverage_report: bool,
    /// Run `cargo clean` before anything else (`--clean`).
    pub force_clean: bool,
    /// Skip the auto-clean disk-pressure check (`--no-clean`).
    pub force_no_clean: bool,
    /// Force a fresh run, ignoring any previously completed steps.
    pub fresh: bool,
    /// Skip `toolchain-sync` on `--fresh` runs (keep the currently pinned
    /// nightly).
    pub skip_toolchain_sync: bool,
    /// Whether sccache was auto-detected and enabled (set by
    /// [`PipelineContext::new`] after inspecting `$PATH`).
    pub sccache_enabled: bool,
}

impl PipelineContext {
    /// Build a [`PipelineContext`] from the parsed CLI, auto-detecting
    /// sccache, resolving `CARGO_TARGET_DIR`, and preparing the non-
    /// verbose log file sink.
    ///
    /// `validation_command` is forwarded from `main` so pipelines that
    /// never touch the release surface (`go` / `check-all` / `phase1`)
    /// can opt out of sccache auto-detection - validation runs prefer a
    /// warm cargo incremental cache over a cold sccache cache for lower
    /// per-run variance.
    pub(crate) fn new(cli: &Cli, validation_command: bool) -> Self {
        let num_cpus = num_cpus::get();
        let max_jobs = cli.jobs.unwrap_or_else(|| num_cpus.min(16));
        // Fan-out: how many cargo invocations run simultaneously.
        // When explicit --jobs is given, honour it as the ceiling.
        // When defaulting, use num_cpus/4 (min 2) so total rustc threads
        // (fanout × CARGO_BUILD_JOBS) stays bounded on dev laptops.
        let fanout_concurrency = cli
            .jobs
            .map_or_else(|| (num_cpus / 4).max(2), |explicit| explicit.min(max_jobs));

        // Build global environment variables
        let mut global_env: Vec<(String, String)> = Vec::new();
        global_env.push(("CARGO_BUILD_JOBS".into(), max_jobs.to_string()));

        // Normalize Cargo's target dir so child cargo/nextest processes
        // don't treat `~/...` from .cargo/config.toml as a literal
        // workspace-relative path segment.
        let cargo_target_dir = get_cargo_target_dir();
        global_env.push((
            "CARGO_TARGET_DIR".into(),
            cargo_target_dir.to_string_lossy().into_owned(),
        ));

        // Optional sccache integration (massive win in CI and on
        // developer machines).
        //
        // As of Phase 3 of dev-flow-implementation-plan.md § 2.1, the
        // CARGO_INCREMENTAL=0 ↔ rustc-wrapper=sccache pairing is enforced
        // in `.cargo/config.toml` directly (`build.incremental = false` +
        // `build.rustc-wrapper = "sccache"`).  `just/shared.just` no
        // longer exports CARGO_INCREMENTAL, so the old drift that caused
        // v0.5.71's Bug B cannot recur: there is now one source of truth
        // and env vars only override when explicitly set (e.g. CI, which
        // sets both to empty/0 to disable sccache on GHA runners).
        //
        // Consequence here: the pipeline only needs to set RUSTC_WRAPPER
        // for its subprocesses (e.g. `git`, whose pre-push hook shells
        // out to cargo - we still inject the wrapper explicitly because
        // git itself reads no Cargo config).
        let disable_sccache = cli.no_sccache || validation_command;
        let sccache_available = !disable_sccache && sccache_is_functional();
        if sccache_available {
            global_env.push(("RUSTC_WRAPPER".into(), "sccache".into()));
        } else {
            // Always clear RUSTC_WRAPPER when sccache is unavailable -
            // .cargo/config.toml hard-codes `build.rustc-wrapper = "sccache"`,
            // so subprocesses would otherwise inherit a broken wrapper and
            // every cargo invocation (even `cargo clean`) would die with
            // "sccache rustc -vV: Operation not permitted".
            global_env.push(("RUSTC_WRAPPER".into(), String::new()));
        }

        // Create log file for non-verbose mode
        let log_file = if cli.verbose {
            None
        } else {
            let log_dir = PathBuf::from("build/logs");
            // Best-effort log dir creation; downstream open() will
            // surface the failure if it actually matters.
            _ = fs::create_dir_all(&log_dir);
            let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
            Some(log_dir.join(format!("ci-pipeline-{timestamp}.log")))
        };

        Self {
            start_time: Instant::now(),
            fanout_concurrency,
            timeout_duration: Duration::from_hours(1), // 60 minutes max
            flags: PipelineFlags {
                verbose: cli.verbose,
                coverage_report: cli.coverage_report,
                force_clean: cli.clean,
                force_no_clean: cli.no_clean,
                fresh: cli.fresh,
                skip_toolchain_sync: cli.skip_toolchain_sync,
                sccache_enabled: sccache_available,
            },
            min_free_gb: cli.min_free_gb,
            max_target_gb: cli.max_target_gb,
            global_env,
            log_file,
        }
    }
}
