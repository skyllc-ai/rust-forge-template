// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 Acmex Placeholder LLC.

#![expect(
    clippy::print_stdout,
    clippy::use_debug,
    reason = "operational CLI tool — workflow status + phase enum (Debug-formatted) go to stdout (issue #212)"
)]

//! Resumable-workflow state machine for the ACMEX ship pipeline.
//!
//! * [`WorkflowPhase`] — coarse-grained pipeline phase (what we're doing).
//! * [`StepTracker`]   — fine-grained set of completed / failed step ids.
//! * [`WorkflowState`] — the whole thing, persisted atomically to
//!   `build/.acmex-workflow-state.json` between runs so `just ship` can resume
//!   from the first non-completed step after a CI-class failure.
//!
//! [`STEP_*`](ALL_STEPS) constants are the step-id source of truth — they
//! are embedded in the on-disk JSON, so renaming one is a
//! backwards-incompatible change to the resumable-state format.

use alloc::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use anyhow::{Context as _, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────────────────
// Step id constants — embedded in the on-disk resumable-state file.
// ─────────────────────────────────────────────────────────────────────────────

/// Ensure the pinned nightly (per `rust-toolchain.toml`) is installed.
pub(crate) const STEP_TOOLCHAIN_SYNC: &str = "00-toolchain-ensure";
// Step 01 (update-polars-git) was removed: Polars is now a plain
// crates.io SemVer dependency (see crates/acmex-polars/Cargo.toml), so
// there is no upstream-main HEAD to chase each ship.  Step numbering is
// preserved to keep in-flight resumable-ship state files compatible.
/// Clean cached build artefacts to recover from stale incremental state.
pub(crate) const STEP_CLEAN_ARTIFACTS: &str = "02-clean-artifacts";
/// Apply `cargo fmt --all` across the workspace.
pub(crate) const STEP_FORMAT_CODE: &str = "03-format-code";
/// Run the coverage-instrumented test pass.
pub(crate) const STEP_COVERAGE_TESTS: &str = "04-coverage-tests";
/// Run the fan-out parallel validation stage (clippy trio + doc + deny).
pub(crate) const STEP_PARALLEL_VALIDATION: &str = "05-parallel-validation";
/// Verify `cargo fmt` produces zero diff (idempotency check).
pub(crate) const STEP_FORMAT_CHECK: &str = "06-format-check";
// Step 07 (version-increment) was removed: version bumping now happens
// automatically via release-plz on the `main` branch after PR merge.
// Step numbering is preserved to keep in-flight resumable-ship state
// files compatible.
// Steps 08 (build-release) and 09 (deploy-binary) were removed: `just
// ship` no longer produces binaries locally.  The release branch PR
// (step 11) lands the version bump on main; `auto-tag-release.yml`
// then tags the commit and invokes `release.yml`, which builds +
// publishes from GitHub Actions.  Step numbering is preserved to keep
// in-flight resumable-ship state files compatible with older pipeline
// runs.
/// Create the `chore: development vX.Y.Z ...` release commit.
pub(crate) const STEP_GIT_COMMIT: &str = "10-git-commit";
/// Push the release branch and open the release PR (branch-protection
/// compatible; does not push directly to `main`).
pub(crate) const STEP_GIT_PUSH: &str = "11-git-push";

/// Canonical ordered list of resumable pipeline steps.  Indexing into
/// this array preserves the 00..11 numbering embedded in each step id
/// even when intermediate steps (08-build-release, 09-deploy-binary)
/// are retired.
pub(crate) const ALL_STEPS: &[&str] = &[
    STEP_CLEAN_ARTIFACTS,
    STEP_FORMAT_CODE,
    STEP_COVERAGE_TESTS,
    STEP_PARALLEL_VALIDATION,
    STEP_FORMAT_CHECK,
    // STEP_VERSION_INCREMENT retired — release-plz handles version bumps
    STEP_GIT_COMMIT,
    STEP_GIT_PUSH,
];

// ─────────────────────────────────────────────────────────────────────────────
// State types
// ─────────────────────────────────────────────────────────────────────────────

/// Coarse-grained pipeline phase.  Serialized into the state file so
/// the workflow can resume at the right high-level stage after a
/// failure.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq, Clone, Copy)]
pub(crate) enum WorkflowPhase {
    /// No pipeline in flight.
    Clean,
    /// Phase 2 step 07: bumping `[workspace.package].version`.
    /// **RETIRED in Phase R5** — version bumping now handled by release-plz.
    /// Preserved for backwards compatibility with existing resumable-state
    /// files.
    VersionIncrementing,
    /// Phase 1 test pass (coverage tests + parallel validation).
    Testing,
    /// Phase 2 build pass (now moved to GitHub Actions via `release.yml`).
    Building,
    /// Phase 2 deploy (retired; binaries are built by GitHub Actions).
    Deploying,
    /// Phase 2 step 10: creating the `chore: development vX.Y.Z` commit.
    GitCommitting,
    /// Phase 2 step 11: pushing the release branch + opening the PR.
    GitPushing,
    /// Pipeline finished end-to-end successfully.
    Completed,
}

/// Fine-grained per-step tracker.  `completed_steps` and `failed_steps`
/// hold `STEP_*` ids; `current_step` is the step actively executing
/// (transient; cleared on step completion/failure).
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub(crate) struct StepTracker {
    /// Step ids that finished successfully in the current workflow.
    pub completed_steps: BTreeSet<String>,
    /// Step ids whose last run failed.
    pub failed_steps: BTreeSet<String>,
    /// Step id currently executing (cleared on completion / failure).
    pub current_step: Option<String>,
}

/// Full resumable workflow state — persisted to
/// `build/.acmex-workflow-state.json` between `just ship` runs.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub(crate) struct WorkflowState {
    /// `[workspace.package].version` at the start of this run.
    pub current_version: String,
    /// Random UUID assigned at workflow creation (for log correlation).
    pub workflow_id: String,
    /// Coarse-grained phase.  See [`WorkflowPhase`].
    pub phase: WorkflowPhase,
    /// When this workflow was started.
    pub started_at: DateTime<Utc>,
    /// When this workflow finished (only set on transition to `Completed`).
    pub completed_at: Option<DateTime<Utc>>,
    /// Last `current_version` that actually shipped — rolled forward
    /// on `Completed`.
    pub last_successful_version: String,
    /// Total failures observed across this workflow's lifetime.
    pub failure_count: u32,
    /// Human-readable text of the most recent failure, if any.
    pub last_error: Option<String>,
    /// Fine-grained per-step state.
    pub step_tracker: StepTracker,
    /// Whether Phase 2 step 07 already bumped the version.  Cached
    /// here so Phase 2 re-runs skip the bump after a successful
    /// previous run.
    pub version_incremented: bool,

    /// Working-tree fingerprint that Phase 1 last validated against (HEAD +
    /// tracked diff, see `ship::working_tree_fingerprint`).  Empty until the
    /// first validation passes.  On a re-run, if the current fingerprint
    /// differs, the code-dependent validation steps are invalidated so they
    /// re-run on the changed code; an unchanged tree keeps the resume speedup.
    #[serde(default)]
    pub validated_fingerprint: String,

    /// Per-step duration metrics (seconds), keyed by the step id (e.g.
    /// `03-coverage-tests`). Stored in the workflow-state file so you
    /// can compare runs over time.
    #[serde(default)]
    pub step_durations_secs: BTreeMap<String, u64>,
}

impl WorkflowState {
    /// On-disk JSON file that persists resumable workflow state between
    /// pipeline invocations.  Lives under `build/` so it inherits the
    /// same `.gitignore` rules as the rest of the target cache.
    const STATE_FILE: &'static str = "build/.acmex-workflow-state.json";

    /// Load workflow state from the on-disk JSON file, or a fresh default
    /// if the file does not yet exist.
    ///
    /// # Errors
    ///
    /// Returns an error if the state file exists but cannot be read, or
    /// if its contents cannot be parsed as JSON (e.g. the file was hand-
    /// edited to an invalid shape).
    pub(crate) fn load() -> Result<Self> {
        let path = Path::new(Self::STATE_FILE);
        if path.exists() {
            let content = fs::read_to_string(path).context("Failed to read workflow state file")?;
            serde_json::from_str(&content).context("Failed to parse workflow state file")
        } else {
            Ok(Self::default())
        }
    }

    /// Persist the workflow state atomically via write-to-temp + rename.
    ///
    /// # Errors
    ///
    /// Returns an error if the state cannot be serialized, the parent
    /// directory cannot be created, the temp file cannot be written, or
    /// the final rename fails.
    pub(crate) fn save(&self) -> Result<()> {
        let content =
            serde_json::to_string_pretty(self).context("Failed to serialize workflow state")?;
        let path = Path::new(Self::STATE_FILE);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).context("Failed to create state directory")?;
        }
        let temp_file = format!("{}.tmp", Self::STATE_FILE);
        fs::write(&temp_file, content).context("Failed to write temporary state file")?;
        fs::rename(&temp_file, Self::STATE_FILE)
            .context("Failed to atomically update state file")?;
        Ok(())
    }

    /// Move the workflow into `new_phase` and persist.  On transition to
    /// `Completed`, also stamps `completed_at` and rolls
    /// `last_successful_version` forward.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::save`] after the in-memory
    /// transition has been applied.
    pub(crate) fn advance_phase(&mut self, new_phase: WorkflowPhase) -> Result<()> {
        println!(
            "🔄 Advancing workflow phase: {:?} → {:?}",
            self.phase, new_phase
        );
        self.phase = new_phase;
        if new_phase == WorkflowPhase::Completed {
            self.completed_at = Some(Utc::now());
            self.last_successful_version = self.current_version.clone();
            println!(
                "🎉 Workflow completed successfully! Version: {}",
                self.current_version
            );
        }
        self.save()
    }

    /// Record `error` as the most recent failure, bump the failure
    /// counter, and persist.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::save`] after the in-memory
    /// update has been applied.
    pub(crate) fn record_error(&mut self, error: &str) -> Result<()> {
        self.failure_count += 1;
        self.last_error = Some(error.to_owned());
        self.save()
    }

    /// Build a fresh workflow state for `current_version`.  Intended
    /// for `--fresh` runs that want to reset the resumable state.
    #[must_use]
    pub(crate) fn new_workflow(current_version: String) -> Self {
        Self {
            current_version,
            workflow_id: Uuid::new_v4().to_string(),
            phase: WorkflowPhase::Clean,
            started_at: Utc::now(),
            completed_at: None,
            last_successful_version: "unknown".to_owned(),
            failure_count: 0,
            last_error: None,
            step_tracker: StepTracker::default(),
            version_incremented: false,
            validated_fingerprint: String::new(),
            step_durations_secs: BTreeMap::new(),
        }
    }

    /// Return `true` if this workflow is currently in an intermediate
    /// phase (i.e. a prior ship run crashed mid-flight) so a `ship
    /// --resume` invocation is meaningful.
    #[must_use]
    pub(crate) const fn is_resumable(&self) -> bool {
        matches!(
            self.phase,
            WorkflowPhase::VersionIncrementing
                | WorkflowPhase::Testing
                | WorkflowPhase::Building
                | WorkflowPhase::Deploying
                | WorkflowPhase::GitCommitting
                | WorkflowPhase::GitPushing
        )
    }

    /// Return `true` if `step` has been marked completed in the current
    /// workflow (persisted in `completed_steps`).
    #[must_use]
    pub(crate) fn is_step_completed(&self, step: &str) -> bool {
        self.step_tracker.completed_steps.contains(step)
    }

    /// Mark `step` as the currently-executing step and clear any prior
    /// failure record for it, then persist.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::save`].
    pub(crate) fn mark_step_started(&mut self, step: &str) -> Result<()> {
        self.step_tracker.current_step = Some(step.to_owned());
        self.step_tracker.failed_steps.remove(step);
        println!("🔄 Starting step: {step}");
        self.save()
    }

    /// Mark `step` as completed, clear any prior failure record, and
    /// persist.  Subsequent calls to `is_step_completed(step)` will
    /// return `true` until the state file is reset.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::save`].
    pub(crate) fn mark_step_completed(&mut self, step: &str) -> Result<()> {
        self.step_tracker.completed_steps.insert(step.to_owned());
        self.step_tracker.failed_steps.remove(step);
        self.step_tracker.current_step = None;
        println!("✅ Completed step: {step}");
        self.save()
    }

    /// Mark `step` as failed with the given `error` string, remove any
    /// prior completed record for that step, and persist.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::record_error`] or
    /// [`Self::save`].
    pub(crate) fn mark_step_failed(&mut self, step: &str, error: &str) -> Result<()> {
        self.step_tracker.failed_steps.insert(step.to_owned());
        self.step_tracker.completed_steps.remove(step);
        self.step_tracker.current_step = None;
        self.record_error(&format!("Step '{step}' failed: {error}"))?;
        println!("❌ Failed step: {step} - {error}");
        self.save()
    }

    /// Forget that a step ever completed so the next call to
    /// `execute_step_with_tracking` re-runs it.  Used for steps whose
    /// "completed" state depends on an external condition (e.g. git
    /// push "completed" only as long as HEAD is still at the pushed
    /// commit).  Without this, Bug A in docs/architecture/dev-flow.md
    /// § 5.1 can silently skip a push when new commits land locally
    /// between ship runs.
    ///
    /// # Errors
    ///
    /// Propagates any failure from [`Self::save`] when the state was
    /// actually mutated (the save is skipped when the step was not
    /// previously completed, so the no-op path cannot error).
    pub(crate) fn invalidate_step(&mut self, step: &str) -> Result<()> {
        let was_completed = self.step_tracker.completed_steps.remove(step);
        self.step_tracker.failed_steps.remove(step);
        if was_completed {
            println!("↻ Invalidated cached state for step: {step}");
            self.save()?;
        }
        Ok(())
    }

    /// Return the subset of `all_steps` that is *not* in
    /// `completed_steps`.  The main caller (`print_ship_resume_banner`
    /// in `crate::ship`) uses this to render the per-run "remaining"
    /// banner.
    #[must_use]
    pub(crate) fn get_pending_steps(&self, all_steps: &[&str]) -> Vec<String> {
        all_steps
            .iter()
            .copied()
            .filter(|step| !self.is_step_completed(step))
            .map(str::to_owned)
            .collect()
    }
}

impl Default for WorkflowState {
    fn default() -> Self {
        Self {
            current_version: "unknown".to_owned(),
            workflow_id: Uuid::new_v4().to_string(),
            phase: WorkflowPhase::Clean,
            started_at: Utc::now(),
            completed_at: None,
            last_successful_version: "unknown".to_owned(),
            failure_count: 0,
            last_error: None,
            step_tracker: StepTracker::default(),
            version_incremented: false,
            validated_fingerprint: String::new(),
            step_durations_secs: BTreeMap::new(),
        }
    }
}

/// Pretty-print the current resumable workflow state to stdout: the
/// phase, completed/failed step counts, last error (if any), and the
/// per-step duration histogram.  Used by the `workflow-status`
/// subcommand.
pub(crate) fn print_workflow_status(state: &WorkflowState) {
    println!("📊 ACMEX Workflow Status");
    println!("═══════════════════════════════════════");
    println!("🔖 Current Version: {}", state.current_version);
    println!("🆔 Workflow ID: {}", state.workflow_id);
    println!("📍 Current Phase: {:?}", state.phase);
    println!(
        "⏰ Started: {}",
        state.started_at.format("%Y-%m-%d %H:%M:%S UTC")
    );

    if let Some(completed) = state.completed_at {
        println!(
            "✅ Completed: {}",
            completed.format("%Y-%m-%d %H:%M:%S UTC")
        );
    }

    println!(
        "🎯 Resumable: {}",
        if state.is_resumable() { "✅" } else { "❌" }
    );

    let completed_count = state.step_tracker.completed_steps.len();
    let total_steps = ALL_STEPS.len();
    println!("📊 Step Progress: {completed_count}/{total_steps} completed");

    if !state.step_tracker.completed_steps.is_empty() {
        println!("✅ Completed Steps:");
        for step in &state.step_tracker.completed_steps {
            println!("   • {step}");
        }
    }

    if !state.step_tracker.failed_steps.is_empty() {
        println!("❌ Failed Steps:");
        for step in &state.step_tracker.failed_steps {
            println!("   • {step}");
        }
    }

    if let Some(current_step) = &state.step_tracker.current_step {
        println!("🔄 Current Step: {current_step}");
    }

    let pending_steps = state.get_pending_steps(ALL_STEPS);
    if !pending_steps.is_empty() {
        println!("📋 Pending Steps:");
        for step in &pending_steps {
            println!("   • {step}");
        }
    }

    if state.failure_count > 0 {
        println!("❌ Failure Count: {}", state.failure_count);
        if let Some(error) = &state.last_error {
            println!("🔍 Last Error: {error}");
        }
    }

    match state.phase {
        WorkflowPhase::Clean | WorkflowPhase::Completed => {
            println!("\n💡 Validate only:    just go");
            println!("💡 Full ship lane:   just ship");
            println!("💡 Fresh ship run:   just ship-fresh");
        }
        WorkflowPhase::VersionIncrementing
        | WorkflowPhase::Testing
        | WorkflowPhase::Building
        | WorkflowPhase::Deploying
        | WorkflowPhase::GitCommitting
        | WorkflowPhase::GitPushing => {
            println!("\n💡 Resume ship workflow: just ship");
            println!("💡 Start fresh:          just ship-fresh");
        }
    }
}
