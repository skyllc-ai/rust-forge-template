// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

#![expect(
    clippy::print_stdout,
    reason = "operational CLI tool — git/gh progress lines go to stdout (issue #212)"
)]

//! `git` + `gh` CLI helpers that Phase 2 of the ship pipeline drives.
//!
//! The entry points are [`git_commit`] (create the `chore: development
//! vX.Y.Z ...` signed commit) and [`git_push`] (push the release
//! branch + open the release PR with auto-merge queued).  Each of the
//! push sub-steps (`ensure_on_release_branch`, `rebase_onto_upstream`,
//! `push_release_branch`, `find_existing_release_pr`, `open_release_pr`,
//! `enable_auto_merge`, `return_to_base_branch`) is its own small helper
//! so a failure points at a named function in the backtrace and
//! refactors stay surgical.
//!
//! The auto-commit is created on the `release/vX.Y.Z` branch (see
//! [`git_commit`] / `switch_to_release_branch`), never on `main`, so a
//! ship leaves local `main` exactly at `origin/main` — no post-merge
//! `git reset --hard` is ever needed.
//!
//! [`count_unpushed_commits`] is the Phase 6 (resumable-push-fix)
//! helper: it lets the ship pipeline detect "HEAD is ahead of
//! `origin/release/<ver>`" and re-run the cached-completed push step
//! instead of silently skipping it.

use anyhow::{Context as _, Result};
use colored::Colorize as _;
use tokio::process::Command;

use crate::context::PipelineContext;
use crate::exec::execute_command;
use crate::version::extract_version_from_cargo_toml;

/// Name of the long-lived base branch the release PR targets.  The
/// ship pipeline never commits onto it locally (see [`git_commit`]); it
/// is only ever the PR base and the branch the developer is left on
/// after a ship.
pub(crate) const BASE_BRANCH: &str = "main";

/// Switch onto the `release/vX.Y.Z` branch (creating or resetting it to
/// the current `HEAD`) so the auto-commit lands there instead of on
/// `main`.  Idempotent: safe to re-run on a resumed ship even if the
/// branch already exists.
///
/// Why this matters: committing on `main` left local `main` permanently
/// 1-ahead of `origin/main`, and after the PR squash-merged the local
/// commit's SHA diverged from GitHub's squashed commit, forcing a
/// `git reset --hard origin/main` after every ship.  Committing on the
/// release branch keeps local `main` exactly at `origin/main`
/// throughout, so a plain `git pull --ff-only` syncs it post-merge.
///
/// `git switch -C` (capital C) creates-or-resets the branch to HEAD,
/// which is exactly the resumable semantics we want: first run creates
/// it at the pre-commit HEAD; a resumed run that is already on the
/// branch (with the commit) re-points it to the same HEAD as a no-op.
///
/// # Errors
///
/// Propagates any failure from the `git switch` subprocess.
async fn switch_to_release_branch(ctx: &PipelineContext, release_branch: &str) -> Result<()> {
    println!(
        "🌿 Switching to release branch {} (commit lands here, not on {})",
        release_branch.cyan(),
        BASE_BRANCH.cyan()
    );
    execute_command(
        "Git switch (release branch)",
        "git",
        &["switch", "-C", release_branch],
        ctx,
    )
    .await
}

/// Create the auto-generated `chore: development vX.Y.Z ... [auto-commit]`
/// commit **on the release branch** (never on `main`).  Commit message
/// shape is stable so the release PR template can parse it.
///
/// Switches onto `release/vX.Y.Z` first (via [`switch_to_release_branch`])
/// so `main` is never mutated by the ship — see that helper's docs for
/// the local-`main`-divergence rationale.
///
/// # Errors
///
/// Propagates any failure from the branch switch, the wrapped `git add`,
/// the Cargo.toml read, or the `git commit` subprocess.
pub(crate) async fn git_commit(ctx: &PipelineContext) -> Result<()> {
    println!("{}", "📝 Creating auto-generated commit...".blue());

    let cargo_toml = std::fs::read_to_string("Cargo.toml").context("Failed to read Cargo.toml")?;
    let version = extract_version_from_cargo_toml(&cargo_toml)?;
    let release_branch = format!("release/v{version}");

    // Land the commit on the release branch, not on `main`.
    switch_to_release_branch(ctx, &release_branch).await?;

    execute_command("Git add", "git", &["add", "."], ctx).await?;
    let commit_message =
        format!("chore: development v{version} - comprehensive testing complete [auto-commit]");
    execute_command("Git commit", "git", &["commit", "-m", &commit_message], ctx).await?;
    Ok(())
}

/// Count commits on the local HEAD that have not yet landed on
/// `origin/<remote_branch>`.
///
/// Phase 6 helper (dev-flow-implementation-plan.md § 6.3) used by the
/// ship pipeline to decide whether a previously-completed
/// `STEP_GIT_PUSH` needs to be re-run.  After a push succeeds the step
/// is cached; if the developer then commits more locally (e.g. to fix
/// a CI-detected audit failure) and re-runs `just ship`, the cached
/// "completed" state would silently skip the push and the new commits
/// would never land.  Counting `origin/<branch>..HEAD` reliably
/// detects that case.
///
/// Special cases:
/// * If the remote ref does not yet exist (first push of a new release branch),
///   `git rev-list` fails — we treat that as "1 unpushed commit" so the push
///   runs.
/// * If HEAD equals the remote ref, the count is 0 and the cached completion is
///   honoured (idempotent re-runs stay cheap).
///
/// # Errors
///
/// Returns an error only when the `git rev-list` subprocess itself
/// cannot be spawned.  A non-zero exit status is treated as the "ref
/// missing" special case and folded into `Ok(1)`.
pub(crate) async fn count_unpushed_commits(remote_branch: &str) -> Result<u64> {
    let remote_ref = format!("origin/{remote_branch}");
    let spec = format!("{remote_ref}..HEAD");
    let out = Command::new("git")
        .args(["rev-list", "--count", &spec])
        .output()
        .await
        .with_context(|| format!("Failed to run git rev-list for {spec}"))?;
    if !out.status.success() {
        // Remote ref doesn't exist yet (first push) — be conservative
        // and treat HEAD as ahead so the push always runs.
        return Ok(1);
    }
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(text.trim().parse::<u64>().unwrap_or(1))
}

// ─────────────────────────────────────────────────────────────────────────────
// `git_push` sub-steps
// ─────────────────────────────────────────────────────────────────────────────

/// Ensure the working tree is on the existing `release_branch` before
/// pushing — without resetting it.
///
/// Uses plain `git switch <branch>` (NOT `-C`): on a resumed ship where
/// `git_commit` was cached-skipped, the release branch already exists
/// with the auto-commit and we must land on *that* commit, not reset the
/// branch to a commit-less `HEAD`.  On a fresh run we are already on the
/// release branch (just created by `git_commit`), so the switch is a
/// no-op.  `git switch` to the already-current branch succeeds silently.
///
/// # Errors
///
/// Propagates any failure from the `git switch` subprocess (e.g. the
/// branch does not exist — which would indicate `git_commit` never ran).
async fn ensure_on_release_branch(ctx: &PipelineContext, release_branch: &str) -> Result<()> {
    execute_command(
        "Git switch (ensure release branch)",
        "git",
        &["switch", release_branch],
        ctx,
    )
    .await
}

/// Rebase the currently-checked-out release branch onto
/// `origin/<BASE_BRANCH>` so the auto-commit lands on top of any
/// intervening mainline changes before the PR is opened.
///
/// (Previously this rebased the *current* branch onto its own upstream
/// — valid when the ship committed on `main`.  Now that the commit
/// lives on `release/vX.Y.Z`, we rebase onto `origin/main` so the PR is
/// based on current mainline.)
///
/// # Errors
///
/// Propagates any failure from the wrapped `git pull --rebase`
/// subprocess (network, merge conflicts, ...).
async fn rebase_onto_upstream(ctx: &PipelineContext) -> Result<()> {
    execute_command(
        "Git pull rebase",
        "git",
        &["pull", "origin", BASE_BRANCH, "--rebase"],
        ctx,
    )
    .await
}

/// Push `HEAD` to `refs/heads/<release_branch>` on `origin`.  No-op /
/// fast-forward when the pipeline is resuming after a previously-
/// failed step 11 that already pushed the same commit.
///
/// # Errors
///
/// Propagates any failure from the wrapped `git push` subprocess.
async fn push_release_branch(ctx: &PipelineContext, release_branch: &str) -> Result<()> {
    let push_ref = format!("HEAD:refs/heads/{release_branch}");
    println!("📤 Pushing HEAD to {}", release_branch.cyan());
    execute_command(
        "Git push (release branch)",
        "git",
        &["push", "origin", &push_ref],
        ctx,
    )
    .await
}

/// Return the PR number of an already-open PR for `release_branch`, or
/// `None` if no open PR exists.  Used by [`git_push`] to keep the
/// PR-creation step idempotent across resumed ship runs.
///
/// # Errors
///
/// Propagates any failure from the wrapped `gh pr list` subprocess.
fn find_existing_release_pr(release_branch: &str) -> Result<Option<String>> {
    let existing_pr_output = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--head",
            release_branch,
            "--state",
            "open",
            "--json",
            "number",
            "-q",
            ".[0].number",
        ])
        .output()
        .context("Failed to query existing release PR via gh")?;
    let trimmed = String::from_utf8_lossy(&existing_pr_output.stdout)
        .trim()
        .to_owned();
    Ok((!trimmed.is_empty()).then_some(trimmed))
}

/// Open a new release PR via `gh pr create`, with the branch-
/// protection-compatible title + body that explains the auto-merge
/// squash strategy.
///
/// # Errors
///
/// Propagates any failure from the wrapped `gh pr create` subprocess.
async fn open_release_pr(
    ctx: &PipelineContext,
    base_branch: &str,
    release_branch: &str,
    version: &str,
) -> Result<()> {
    let pr_title = format!("chore: release v{version} — ship pipeline auto-commit");
    let pr_body = format!(
        "## Summary\n\n\
         `just ship` Phase 2 auto-commit for **v{version}** — the \
         `[workspace.package].version` bump in `Cargo.toml`.  This PR \
         routes that commit through branch-protection rules.  Once it \
         merges to `{base_branch}`, run `just release-tag` to cut the \
         signed `v{version}` tag, which fires `release.yml` and builds \
         the cross-platform binaries + GitHub Release v{version}.  \
         (No auto-tag on merge — the tag step is manual on-demand, \
         Path B.)\n\n\
         ## Auto-merge\n\n\
         `--auto --squash` is queued — GitHub will merge as soon as the \
         required status checks pass.  Squash is required because \
         `main-protection` mandates signed commits, and GitHub's \
         rebase-auto-merge cannot sign the rebased commit; the \
         squash-merge commit is signed by GitHub's own key, which \
         satisfies `required_signatures: true`.  The original author's \
         signed commit remains verifiable in the PR branch history.\n\n\
         ## After merge\n\n\
         The auto-commit lived only on `{release_branch}`, so local \
         `{base_branch}` never drifted — sync it with a plain \
         `git pull --ff-only origin {base_branch}` (no `reset --hard` \
         needed)."
    );

    println!("📬 Opening release PR");
    execute_command(
        "Open release PR",
        "gh",
        &[
            "pr",
            "create",
            "--base",
            base_branch,
            "--head",
            release_branch,
            "--title",
            &pr_title,
            "--body",
            &pr_body,
        ],
        ctx,
    )
    .await
}

/// Enable GitHub auto-merge with the squash strategy for the release
/// PR.
///
/// Squash is mandatory on this repo because:
///
///   1. `main-protection` requires `required_signatures: true` (every commit on
///      main must be signed).
///   2. GitHub's rebase-auto-merge cannot sign the rebased commit; it fails
///      with `GraphQL: Base branch requires signed commits. Rebase merges
///      cannot be automatically signed by GitHub` (observed on PR #36, the
///      first real `just ship` for v0.5.69).
///   3. GitHub signs the squash-merge commit with its own key, which satisfies
///      `required_signatures: true` on main.
///
/// Trust trade-off: the author's GPG signature is lost on the commit
/// that lands on main (it becomes a GitHub-signed squash).  The
/// original signed commit remains verifiable in the PR branch history,
/// and every prior merged PR on this repo uses the same pattern.
///
/// # Errors
///
/// Propagates any failure from the wrapped `gh pr merge` subprocess.
async fn enable_auto_merge(ctx: &PipelineContext, release_branch: &str) -> Result<()> {
    println!("⚡ Ensuring auto-merge is enabled (squash strategy)");
    execute_command(
        "Enable auto-merge",
        "gh",
        &["pr", "merge", release_branch, "--auto", "--squash"],
        ctx,
    )
    .await
}

/// Push the release branch and open the release PR against
/// [`BASE_BRANCH`].  Branch-protection compatible: never pushes
/// directly to `main`.
///
/// Thin orchestrator — each sub-step lives in its own helper
/// ([`ensure_on_release_branch`], [`rebase_onto_upstream`],
/// [`push_release_branch`], [`find_existing_release_pr`],
/// [`open_release_pr`], [`enable_auto_merge`], [`return_to_base_branch`])
/// so the control flow stays readable and individual failures map 1:1
/// to a named helper in the backtrace.
///
/// # Errors
///
/// Propagates any failure from the helper subprocesses.  The version
/// lookup via [`crate::version::get_current_version`] is the one
/// non-subprocess error source.
pub(crate) async fn git_push(ctx: &PipelineContext) -> Result<()> {
    println!(
        "{}",
        "🚀 Opening release PR (branch-protection-compatible)...".blue()
    );

    // The auto-commit was made on the release branch by `git_commit`, so
    // that is the branch checked out here.  Derive its name from the
    // version Phase 2 step 07 bumped (example: `release/v0.5.68`).
    let version = crate::version::get_current_version()?;
    let release_branch = format!("release/v{version}");
    println!("📌 Release branch: {}", release_branch.cyan());

    // Resilience for resumed ships: if step 10 (git_commit) was
    // cached-complete this run, we were NOT switched onto the release
    // branch — and a prior git_push may have already switched us back to
    // `main`.  Re-checkout the existing release branch (plain `switch`,
    // NOT `-C`, so we land on the branch that already holds the
    // auto-commit rather than resetting it to a commit-less HEAD).
    ensure_on_release_branch(ctx, &release_branch).await?;

    // Rebase the release branch onto current mainline before opening the
    // PR (keeps the PR based on the latest `origin/main`).
    rebase_onto_upstream(ctx).await?;

    push_release_branch(ctx, &release_branch).await?;

    // Idempotent PR creation: reuse an existing open PR for the same
    // release branch if the pipeline is resuming from a previously-
    // failed step 11.  Base is always `main` — the ship never targets
    // any other branch.
    match find_existing_release_pr(&release_branch)? {
        Some(pr_number) => {
            println!("ℹ️  Reusing existing release PR #{}", pr_number.cyan());
        }
        None => {
            open_release_pr(ctx, BASE_BRANCH, &release_branch, &version).await?;
        }
    }

    enable_auto_merge(ctx, &release_branch).await?;

    // Leave the developer back on `main`, untouched and exactly at
    // `origin/main`.  Because the commit only ever lived on the release
    // branch, local `main` never drifted — after the PR squash-merges,
    // a plain `git pull --ff-only` syncs it (no `reset --hard` needed).
    return_to_base_branch(ctx).await?;

    println!(
        "{} Release PR for v{} opened with auto-merge queued",
        "✅".green(),
        version
    );
    println!(
        "   💡 Watch checks: {}",
        format!("gh pr checks {release_branch} --watch").cyan()
    );
    println!(
        "   💡 After merge:  {}",
        format!("git pull --ff-only origin {BASE_BRANCH} (local {BASE_BRANCH} never drifted)")
            .cyan()
    );

    Ok(())
}

/// Switch the working tree back to [`BASE_BRANCH`] after the release PR
/// has been opened, so the developer is left where they started.
///
/// Best-effort: a failure here does not undo the already-opened PR, so
/// it is logged but not fatal — the ship's real deliverable (the PR +
/// queued auto-merge) is already done by the time this runs.
///
/// # Errors
///
/// Never returns `Err` — a failed switch is downgraded to a warning so
/// it cannot fail an otherwise-successful ship.
async fn return_to_base_branch(ctx: &PipelineContext) -> Result<()> {
    println!("🔙 Returning to {}", BASE_BRANCH.cyan());
    if let Err(err) =
        execute_command("Git switch (base)", "git", &["switch", BASE_BRANCH], ctx).await
    {
        println!(
            "{} could not switch back to {BASE_BRANCH} ({err}); you are still on the release branch",
            "⚠️".yellow()
        );
    }
    Ok(())
}
