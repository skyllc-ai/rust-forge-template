// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "operational CLI tool — step progress to stdout, error details to stderr (issue #212)"
)]

//! Subprocess execution primitives for the ACMEX CI pipeline.
//!
//! * [`execute_command`] / [`execute_command_with_env`] — spawn a single
//!   subprocess under the pipeline's timeout, logging, and progress- spinner
//!   conventions.
//! * [`execute_parallel`] / [`execute_parallel_with_env`] — fan out a
//!   `Vec<(name, cmd, args)>` concurrently via `try_join_all`, bounded by the
//!   `fanout_concurrency` semaphore.
//! * [`execute_step_with_tracking`] — adapter that wraps a `FnOnce() ->
//!   Future<Result<()>>` in the resumable-workflow tracking contract
//!   (mark-started → run → mark-completed/failed + record duration).
//!
//! `create_fillup_spinner` is a private helper for
//! `execute_command_with_env`'s non-verbose output mode.

use core::future::Future;
use core::time::Duration;
use std::io::Write as _;
use std::process::Stdio;
use std::time::Instant;

use anyhow::{Context as _, Result, bail};
use colored::Colorize as _;
use futures::future::try_join_all;
use indicatif::{ProgressBar, ProgressStyle};
use tokio::process::Command;
use tokio::time::timeout;

use crate::context::PipelineContext;
use crate::workflow::WorkflowState;

// ─────────────────────────────────────────────────────────────────────────────
// Progress spinner
// ─────────────────────────────────────────────────────────────────────────────

/// Create a fillup-style progress spinner used in non-verbose mode so
/// the operator sees per-step progress without tens of thousands of
/// lines of cargo output flooding the terminal.
fn create_fillup_spinner(message: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    let fillup_frames = vec![
        "▱▱▱▱▱▱▱▱▱▱",
        "▰▱▱▱▱▱▱▱▱▱",
        "▰▰▱▱▱▱▱▱▱▱",
        "▰▰▰▱▱▱▱▱▱▱",
        "▰▰▰▰▱▱▱▱▱▱",
        "▰▰▰▰▰▱▱▱▱▱",
        "▰▰▰▰▰▰▱▱▱▱",
        "▰▰▰▰▰▰▰▱▱▱",
        "▰▰▰▰▰▰▰▰▱▱",
        "▰▰▰▰▰▰▰▰▰▱",
        "▰▰▰▰▰▰▰▰▰▰",
        "▱▰▰▰▰▰▰▰▰▰",
        "▱▱▰▰▰▰▰▰▰▰",
        "▱▱▱▰▰▰▰▰▰▰",
        "▱▱▱▱▰▰▰▰▰▰",
        "▱▱▱▱▱▰▰▰▰▰",
        "▱▱▱▱▱▱▰▰▰▰",
        "▱▱▱▱▱▱▱▰▰▰",
        "▱▱▱▱▱▱▱▱▰▰",
        "▱▱▱▱▱▱▱▱▱▰",
    ];
    // Template parse cannot realistically fail here (the template
    // string is constructed from a compile-time-constant format pattern
    // plus a message that only supplies the literal text), but the
    // indicatif API forces a `Result`.  Fall back to the plain tick-
    // string-only spinner if the (unreachable) error path ever fires —
    // the user still gets a working progress indicator, just without
    // the message prefix.
    let style = ProgressStyle::default_spinner()
        .tick_strings(&fillup_frames)
        .template(&format!("{{spinner}} {}", message.cyan()))
        .unwrap_or_else(|_| ProgressStyle::default_spinner().tick_strings(&fillup_frames));
    pb.set_style(style);
    pb.enable_steady_tick(Duration::from_millis(150));
    pb
}

// ─────────────────────────────────────────────────────────────────────────────
// Single-command execution
// ─────────────────────────────────────────────────────────────────────────────

/// Spawn `cmd` with the given `args` under the pipeline's timeout +
/// logging conventions, injecting both the context-wide `global_env`
/// and the per-call `env` overrides.  On non-verbose runs the captured
/// output is tee'd to `ctx.log_file`; stderr of failed commands is
/// re-printed so the diagnosis is visible even without `--verbose`.
pub(crate) async fn execute_command_with_env(
    name: &str,
    cmd: &str,
    args: &[&str],
    env_vars: &[(&str, &str)],
    ctx: &PipelineContext,
) -> Result<()> {
    let step_start = Instant::now();
    if ctx.flags.verbose {
        println!(
            "{} {} → {} {} (env: {:?})",
            "→".blue().bold(),
            name.cyan(),
            cmd.yellow(),
            args.join(" ").dimmed(),
            env_vars
        );
    } else {
        println!("{} {}", "→".blue().bold(), name.cyan());
    }

    let mut command = Command::new(cmd);
    command.args(args);

    // Apply global environment variables first
    for (key, value) in &ctx.global_env {
        command.env(key, value);
    }

    // Then apply step-specific environment variables (can override globals)
    for (key, value) in env_vars {
        command.env(key, value);
    }

    // NOTE: the `CARGO_INCREMENTAL=0` ↔ `rustc-wrapper=sccache` pairing
    // is now enforced at the Cargo-config layer (`.cargo/config.toml`
    // sets both `build.incremental = false` and `build.rustc-wrapper =
    // "sccache"` as of Phase 3 of dev-flow-implementation-plan.md §
    // 2.1).  The pipeline still re-asserts `RUSTC_WRAPPER=sccache` in
    // its global env so that `git` (whose pre-push hook shells out to
    // cargo but reads no Cargo config itself) inherits the same
    // wrapper.

    // In verbose mode, inherit stdio; otherwise capture to log file
    if ctx.flags.verbose {
        command.stdout(Stdio::inherit()).stderr(Stdio::inherit());
    } else {
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
    }

    let child = command
        .spawn()
        .with_context(|| format!("Failed to spawn command '{cmd}' for step '{name}'"))?;
    let progress_bar = if ctx.flags.verbose {
        None
    } else {
        Some(create_fillup_spinner(name))
    };

    let result = timeout(ctx.timeout_duration, child.wait_with_output())
        .await
        .with_context(|| {
            format!(
                "Command '{}' timed out after {}s",
                cmd,
                ctx.timeout_duration.as_secs()
            )
        })?
        .with_context(|| format!("Failed to wait for command '{cmd}' in step '{name}'"))?;

    if let Some(pb) = progress_bar {
        pb.finish_and_clear();
    }
    let duration = step_start.elapsed();

    // Write output to log file if available
    if let Some(log_path) = &ctx.log_file
        && let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path)
    {
        // Best-effort diagnostic log; discard write errors so a full
        // disk or revoked permission doesn't abort the pipeline.
        _ = writeln!(file, "\n=== {name} ({cmd}) ===");
        _ = writeln!(file, "Command: {} {}", cmd, args.join(" "));
        _ = writeln!(file, "Duration: {}s", duration.as_secs());
        if !result.stdout.is_empty() {
            _ = writeln!(file, "--- stdout ---");
            _ = file.write_all(&result.stdout);
        }
        if !result.stderr.is_empty() {
            _ = writeln!(file, "--- stderr ---");
            _ = file.write_all(&result.stderr);
        }
    }

    if result.status.success() {
        println!("{} {} ({}s)", "✅".green(), name, duration.as_secs());
        Ok(())
    } else {
        let exit_code = result
            .status
            .code()
            .map_or_else(|| "unknown".to_owned(), |code| code.to_string());
        println!("{} {} failed (exit code: {})", "❌".red(), name, exit_code);

        // Print stderr on failure even in non-verbose mode
        if !ctx.flags.verbose && !result.stderr.is_empty() {
            eprintln!("{}", String::from_utf8_lossy(&result.stderr));
        }

        bail!(
            "Step '{}' failed: command '{}' exited with code {} after {}s",
            name,
            cmd,
            exit_code,
            duration.as_secs()
        );
    }
}

/// Thin wrapper around [`execute_command_with_env`] for callers that
/// don't need per-call env overrides beyond the context's global set.
pub(crate) async fn execute_command(
    name: &str,
    cmd: &str,
    args: &[&str],
    ctx: &PipelineContext,
) -> Result<()> {
    execute_command_with_env(name, cmd, args, &[], ctx).await
}

// ─────────────────────────────────────────────────────────────────────────────
// Parallel fan-out
// ─────────────────────────────────────────────────────────────────────────────

/// Fan out every `(name, cmd, args)` tuple in parallel via
/// `try_join_all` and abort on the first failure.  Used by the
/// parallel-validation stage.
pub(crate) async fn execute_parallel(
    commands: Vec<(&str, &str, Vec<&str>)>,
    ctx: &PipelineContext,
) -> Result<()> {
    let parallel_start = Instant::now();
    let command_count = commands.len();
    println!(
        "{} Running {} commands in parallel...",
        "🔄".yellow(),
        command_count
    );

    let semaphore = alloc::sync::Arc::new(tokio::sync::Semaphore::new(ctx.fanout_concurrency));
    let tasks: Vec<_> = commands
        .into_iter()
        .map(|(name, cmd, args)| {
            let permit_source = alloc::sync::Arc::clone(&semaphore);
            async move {
                let _permit = permit_source
                    .acquire()
                    .await
                    .context("Failed to acquire semaphore")?;
                execute_command(name, cmd, &args, ctx)
                    .await
                    .with_context(|| format!("Parallel execution failed for '{name}'"))
            }
        })
        .collect();

    try_join_all(tasks).await.with_context(|| {
        format!("Parallel execution failed - one or more of {command_count} commands failed")
    })?;
    println!(
        "{} Parallel execution completed ({}s)",
        "✅".green(),
        parallel_start.elapsed().as_secs()
    );
    Ok(())
}

/// [`execute_parallel`] variant that applies the same `env_vars` to
/// every spawned subprocess.  Kept separate so callers that don't need
/// env overrides pay no allocation cost to model them.
pub(crate) async fn execute_parallel_with_env(
    commands: Vec<(&str, &str, Vec<&str>)>,
    env_vars: &[(&str, &str)],
    ctx: &PipelineContext,
) -> Result<()> {
    let parallel_start = Instant::now();
    let command_count = commands.len();
    println!(
        "{} Running {} commands in parallel with env vars...",
        "⚡".yellow(),
        command_count
    );

    let semaphore = alloc::sync::Arc::new(tokio::sync::Semaphore::new(ctx.fanout_concurrency));
    let env_vars_template = env_vars.to_vec();
    let tasks: Vec<_> = commands
        .into_iter()
        .map(|(name, cmd, args)| {
            let permit_source = alloc::sync::Arc::clone(&semaphore);
            let task_env = env_vars_template.clone();
            async move {
                let _permit = permit_source
                    .acquire()
                    .await
                    .context("Failed to acquire semaphore")?;
                execute_command_with_env(name, cmd, &args, &task_env, ctx)
                    .await
                    .with_context(|| format!("Parallel execution failed for '{name}'"))
            }
        })
        .collect();

    try_join_all(tasks).await.with_context(|| {
        format!("Parallel execution failed - one or more of {command_count} commands failed")
    })?;
    println!(
        "{} Parallel execution completed ({}s)",
        "✅".green(),
        parallel_start.elapsed().as_secs()
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Resumable-workflow step adapter
// ─────────────────────────────────────────────────────────────────────────────

/// Run `step_fn` under the resumable-workflow tracker.  Skips if the
/// step is already marked completed in `state`, otherwise records
/// started → completed / failed transitions around the call.  The
/// duration is recorded in `state.step_durations_secs` for per-run
/// performance comparison.
///
/// # Errors
///
/// Propagates the inner future's error verbatim, after recording the
/// failure into `state` via [`WorkflowState::mark_step_failed`].  Any
/// failure from the state-file write surfaces as a separate error.
pub(crate) async fn execute_step_with_tracking<F, Fut>(
    state: &mut WorkflowState,
    step_name: &str,
    step_fn: F,
) -> Result<()>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<()>>,
{
    if state.is_step_completed(step_name) {
        println!("⏭️  Skipping completed step: {step_name}");
        return Ok(());
    }
    state.mark_step_started(step_name)?;

    let step_start = Instant::now();
    let result = step_fn().await;
    let duration_secs = step_start.elapsed().as_secs();

    // Record step duration regardless of success/failure
    state
        .step_durations_secs
        .insert(step_name.to_owned(), duration_secs);

    match result {
        Ok(()) => {
            state.mark_step_completed(step_name)?;
            Ok(())
        }
        Err(err) => {
            state.mark_step_failed(step_name, &err.to_string())?;
            Err(err)
        }
    }
}
