// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! Properties 5 to 8: what every workflow shares, checked across all
//! of them.
//!
//! The structural validator (properties 1 to 4) reads `pr-fast.yml`
//! only, because that is the file the gate manifest drives. The
//! release, preview, nightly and dependabot workflows are hand-written
//! and were outside every check, which is exactly where they drift:
//! one action pinned at two SHAs, a zig version bumped in one job and
//! not the other, a target's RUSTFLAGS copied with a typo, a nextest
//! profile renamed in `.config/nextest.toml` and not in the workflow
//! that names it. These four checks read every `*.yml` under
//! `.github/workflows` with the same read-only posture as the rest of
//! the tool: they can fail a push, never rewrite a file.
//!
//! 5. One pin per action: every `uses: owner/name@<sha>` for a given action
//!    resolves to the same SHA across all workflows.
//! 6. Toolchain versions: every `ziglang==<v>` and `cargo-zigbuild@<v>` matches
//!    `[toolchain]` in the manifest.
//! 7. Build targets: a matrix row `target: T` followed by `rustflags: "X"`, and
//!    a job that names `--target T` under a `RUSTFLAGS: "X"`, carry the flags
//!    `[[target]]` gives for `T`; `target-cpu=native` is refused anywhere.
//! 8. Nextest profiles: every `--profile <name>` names a `[profile.<name>]` in
//!    `.config/nextest.toml`.

use alloc::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anyhow::{Context as _, Result};
use regex::Regex;

use crate::manifest::Manifest;

/// One workflow file's text, with its name for messages.
struct WorkflowText {
    /// The file name (`release.yml`).
    name: String,
    /// The file's contents.
    text: String,
}

/// Runs properties 5 to 8 over every workflow in `workflows_dir`.
///
/// # Errors
/// An unreadable directory or file, or an invalid built-in regex.
pub(crate) fn check(
    manifest: &Manifest,
    workflows_dir: &Path,
    nextest_toml: &Path,
) -> Result<Vec<String>> {
    let workflows = read_workflows(workflows_dir)?;
    let profiles = nextest_profiles(nextest_toml);
    let mut issues = Vec::new();
    issues.extend(check_action_pins(&workflows)?);
    issues.extend(check_toolchain(manifest, &workflows)?);
    issues.extend(check_targets(manifest, &workflows)?);
    issues.extend(check_profiles(&profiles, &workflows)?);
    Ok(issues)
}

/// Every `*.yml` under the directory, sorted by name.
fn read_workflows(dir: &Path) -> Result<Vec<WorkflowText>> {
    let mut out = Vec::new();
    let entries =
        std::fs::read_dir(dir).with_context(|| format!("read workflows at {}", dir.display()))?;
    for found in entries {
        let entry = found?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("yml") {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("read workflow {}", path.display()))?;
        out.push(WorkflowText { name, text });
    }
    out.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(out)
}

/// The `[profile.<name>]` names in the nextest config (empty when the
/// file is absent: property 8 then reports every named profile).
fn nextest_profiles(path: &Path) -> BTreeSet<String> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    text.lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("[profile.")
                .and_then(|rest| rest.split(['.', ']']).next())
                .map(str::to_owned)
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────
// Property 5 - one pin per action
// ─────────────────────────────────────────────────────────────────────

/// Every action pinned at more than one SHA across the workflows.
fn check_action_pins(workflows: &[WorkflowText]) -> Result<Vec<String>> {
    let pin = Regex::new(r"uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@([0-9a-f]{40})")?;
    let mut pins: BTreeMap<String, BTreeMap<String, BTreeSet<String>>> = BTreeMap::new();
    for workflow in workflows {
        for capture in pin.captures_iter(&workflow.text) {
            let action = capture.get(1).map_or("", |hit| hit.as_str()).to_owned();
            let sha = capture.get(2).map_or("", |hit| hit.as_str()).to_owned();
            pins.entry(action)
                .or_default()
                .entry(sha)
                .or_default()
                .insert(workflow.name.clone());
        }
    }
    Ok(pins
        .iter()
        .filter(|(_action, by_sha)| by_sha.len() > 1)
        .map(|(action, by_sha)| {
            let spread: Vec<String> = by_sha
                .iter()
                .map(|(sha, files)| {
                    format!(
                        "{} in {}",
                        sha.get(..7).unwrap_or(sha),
                        files.iter().cloned().collect::<Vec<_>>().join(", ")
                    )
                })
                .collect();
            format!(
                "property 5 (one pin per action): `{action}` is pinned at {} SHAs: {}",
                by_sha.len(),
                spread.join("; ")
            )
        })
        .collect())
}

// ─────────────────────────────────────────────────────────────────────
// Property 6 - toolchain versions
// ─────────────────────────────────────────────────────────────────────

/// Every toolchain mention that disagrees with `[toolchain]`.
fn check_toolchain(manifest: &Manifest, workflows: &[WorkflowText]) -> Result<Vec<String>> {
    let matchers: [(&str, Regex); 2] = [
        ("ziglang", Regex::new("ziglang==([0-9][0-9.]*)")?),
        (
            "cargo-zigbuild",
            Regex::new("cargo-zigbuild@([0-9][0-9.]*)")?,
        ),
    ];
    let mut issues = Vec::new();
    for (key, wanted) in &manifest.toolchain {
        let Some((_name, matcher)) = matchers.iter().find(|(name, _re)| name == key) else {
            issues.push(format!(
                "property 6 (toolchain): `[toolchain] {key}` has no matcher in acmex-gen-workflow \
                 (known: ziglang, cargo-zigbuild)"
            ));
            continue;
        };
        for workflow in workflows {
            for capture in matcher.captures_iter(&workflow.text) {
                let found = capture.get(1).map_or("", |hit| hit.as_str());
                if found != wanted {
                    issues.push(format!(
                        "property 6 (toolchain): {} pins {key} {found}; the manifest says {wanted}",
                        workflow.name
                    ));
                }
            }
        }
    }
    Ok(issues)
}

// ─────────────────────────────────────────────────────────────────────
// Property 7 - build targets and their flags
// ─────────────────────────────────────────────────────────────────────

/// One job's flags and the targets its steps name.
struct JobTargets {
    /// The job key.
    name: String,
    /// The job-level `RUSTFLAGS`, when set.
    flags: Option<String>,
    /// Every `--target` the steps name.
    targets: BTreeSet<String>,
}

/// Matrix rows and jobs whose flags differ from `[[target]]`, and any
/// `target-cpu=native`.
fn check_targets(manifest: &Manifest, workflows: &[WorkflowText]) -> Result<Vec<String>> {
    let table: BTreeMap<&str, &str> = manifest
        .targets
        .iter()
        .map(|row| (row.target.as_str(), row.rustflags.as_str()))
        .collect();
    let matrix_target = Regex::new(r#"^\s*-?\s*target:\s*"?([A-Za-z0-9_-]+)"?\s*$"#)?;
    let matrix_flags = Regex::new(r#"^\s*rustflags:\s*"([^"]*)"\s*$"#)?;
    let mut issues = Vec::new();
    for workflow in workflows {
        let lines: Vec<&str> = workflow.text.lines().collect();
        for (index, line) in lines.iter().enumerate() {
            // A comment saying "never target-cpu=native" is not a use of it.
            if line.trim_start().starts_with('#') {
                continue;
            }
            if let Some(capture) = matrix_target.captures(line) {
                let target = capture.get(1).map_or("", |hit| hit.as_str());
                if let Some(wanted) = table.get(target) {
                    for later in lines.iter().skip(index + 1).take(4) {
                        if let Some(flags) = matrix_flags.captures(later) {
                            let found = flags.get(1).map_or("", |hit| hit.as_str());
                            if found != *wanted {
                                issues.push(format!(
                                    "property 7 (targets): {} matrix row {target} carries \
                                     rustflags \"{found}\"; the manifest says \"{wanted}\"",
                                    workflow.name
                                ));
                            }
                        }
                    }
                }
            }
            if line.contains("target-cpu=native") {
                issues.push(format!(
                    "property 7 (targets): {} line {} sets target-cpu=native (never: the \
                     binary would SIGILL on another runner)",
                    workflow.name,
                    index + 1
                ));
            }
        }
        for job in jobs_of(&lines)? {
            let Some(found) = job.flags else {
                continue;
            };
            for target in job.targets {
                if let Some(wanted) = table.get(target.as_str())
                    && found != *wanted
                {
                    issues.push(format!(
                        "property 7 (targets): {} job `{}` builds {target} under \
                         RUSTFLAGS \"{found}\"; the manifest says \"{wanted}\"",
                        workflow.name, job.name
                    ));
                }
            }
        }
    }
    Ok(issues)
}

/// The jobs of a workflow with their job-level `RUSTFLAGS` and the
/// `--target` triples their steps name.
fn jobs_of(lines: &[&str]) -> Result<Vec<JobTargets>> {
    let env_flags = Regex::new(r#"^\s*RUSTFLAGS:\s*"([^"]*)"\s*$"#)?;
    let cli_target = Regex::new(r"--target\s+([A-Za-z0-9_-]+)")?;
    let job_key = Regex::new(r"^  ([A-Za-z0-9_-]+):\s*$")?;
    let mut in_jobs = false;
    let mut current: Option<JobTargets> = None;
    let mut jobs: Vec<JobTargets> = Vec::new();
    for line in lines {
        if line.trim_end() == "jobs:" {
            in_jobs = true;
            continue;
        }
        if !in_jobs {
            continue;
        }
        if let Some(capture) = job_key.captures(line) {
            if let Some(done) = current.take() {
                jobs.push(done);
            }
            current = Some(JobTargets {
                name: capture.get(1).map_or("", |hit| hit.as_str()).to_owned(),
                flags: None,
                targets: BTreeSet::new(),
            });
            continue;
        }
        let Some(job) = current.as_mut() else {
            continue;
        };
        if let Some(capture) = env_flags.captures(line)
            && line_indent(line) <= 6
        {
            job.flags = capture.get(1).map(|hit| hit.as_str().to_owned());
        }
        for capture in cli_target.captures_iter(line) {
            job.targets
                .insert(capture.get(1).map_or("", |hit| hit.as_str()).to_owned());
        }
    }
    if let Some(done) = current.take() {
        jobs.push(done);
    }
    Ok(jobs)
}

/// Leading spaces of a line.
fn line_indent(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

// ─────────────────────────────────────────────────────────────────────
// Property 8 - nextest profiles
// ─────────────────────────────────────────────────────────────────────

/// Every `--profile <name>` a nextest invocation names that the
/// nextest config does not define (`rustup toolchain install
/// --profile minimal` is not nextest's profile; only lines that run
/// nextest count, backslash continuations joined).
fn check_profiles(profiles: &BTreeSet<String>, workflows: &[WorkflowText]) -> Result<Vec<String>> {
    let named = Regex::new(r"nextest\s+(?:run|archive)\b[^\n]*?--profile\s+([A-Za-z0-9_-]+)")?;
    let mut issues = Vec::new();
    for workflow in workflows {
        let mut seen = BTreeSet::new();
        let joined = logical_lines(&workflow.text);
        for capture in named.captures_iter(&joined) {
            let profile = capture.get(1).map_or("", |hit| hit.as_str());
            if profiles.contains(profile) || !seen.insert(profile.to_owned()) {
                continue;
            }
            issues.push(format!(
                "property 8 (nextest profiles): {} names `--profile {profile}`, which \
                 .config/nextest.toml does not define",
                workflow.name
            ));
        }
    }
    Ok(issues)
}

/// The text with backslash-continued lines joined, so a command split
/// over several lines reads as one.
fn logical_lines(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        if let Some(head) = line.trim_end().strip_suffix('\\') {
            out.push_str(head);
            out.push(' ');
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use alloc::collections::{BTreeMap, BTreeSet};

    use super::{
        WorkflowText, check, check_action_pins, check_profiles, check_targets, check_toolchain,
        read_workflows,
    };
    use crate::manifest::{Manifest, TargetRow};

    /// A scratch directory under the system temp dir, unique per test
    /// process, removed on drop. (No `tempfile` dependency: the workspace
    /// keeps its dev-dependency tree lean and vetted.)
    struct ScratchDir(std::path::PathBuf);

    impl ScratchDir {
        /// Creates `<temp>/acmex-gen-workflow-<pid>-<name>`.
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir()
                .join(format!("acmex-gen-workflow-{}-{name}", std::process::id()));
            std::fs::create_dir_all(&path).expect("scratch dir");
            Self(path)
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _removed = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Only `*.yml` files are read, in name order, and the full check
    /// over a consistent directory reports nothing.
    #[test]
    fn a_workflows_directory_is_read_in_name_order_and_checks_clean() {
        let dir = ScratchDir::new("workflows");
        std::fs::write(
            dir.0.join("b.yml"),
            "jobs:\n  x:\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7\n",
        )
        .expect("write b");
        std::fs::write(
            dir.0.join("a.yml"),
            "jobs:\n  y:\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7\n",
        )
        .expect("write a");
        std::fs::write(dir.0.join("notes.md"), "not a workflow\n").expect("write md");
        let names: Vec<String> = read_workflows(&dir.0)
            .expect("readable")
            .into_iter()
            .map(|workflow| workflow.name)
            .collect();
        assert_eq!(names, ["a.yml", "b.yml"], "yml only, sorted by name");
        let issues =
            check(&manifest(), &dir.0, &dir.0.join("absent-nextest.toml")).expect("checks run");
        assert!(
            issues.is_empty(),
            "a consistent directory is clean: {issues:?}"
        );
    }

    /// A workflow fixture by name and body.
    fn workflow(name: &str, text: &str) -> WorkflowText {
        WorkflowText {
            name: name.to_owned(),
            text: text.to_owned(),
        }
    }

    /// A manifest fixture with one toolchain pin and one target row.
    fn manifest() -> Manifest {
        let mut toolchain = BTreeMap::new();
        toolchain.insert(String::from("ziglang"), String::from("0.14.1"));
        Manifest {
            gates: Vec::new(),
            toolchain,
            targets: vec![TargetRow {
                target: String::from("x86_64-pc-windows-msvc"),
                rustflags: String::from("-C target-cpu=x86-64-v3"),
            }],
        }
    }

    /// Two pins of one action across two files is one finding naming both.
    #[test]
    fn two_pins_of_one_action_are_named() {
        let first = workflow(
            "a.yml",
            "      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7\n",
        );
        let second = workflow(
            "b.yml",
            "      - uses: actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v7\n",
        );
        let issues = check_action_pins(&[first, second]).expect("regex");
        assert_eq!(issues.len(), 1, "{issues:?}");
        assert!(
            issues
                .first()
                .is_some_and(|line| line.contains("actions/checkout") && line.contains("a.yml")),
            "the finding names the action and the first file: {issues:?}"
        );
    }

    /// A zig version that disagrees with the manifest is named with both
    /// values.
    #[test]
    fn a_toolchain_version_off_the_manifest_is_named() {
        let stale = workflow(
            "release.yml",
            "          python3 -m pip install --user \"ziglang==0.13.0\"\n",
        );
        let issues = check_toolchain(&manifest(), &[stale]).expect("regex");
        assert_eq!(issues.len(), 1, "{issues:?}");
        assert!(
            issues
                .first()
                .is_some_and(|line| line.contains("0.13.0") && line.contains("0.14.1")),
            "the finding names both versions: {issues:?}"
        );
    }

    /// A matrix row with the wrong flags, a job whose RUSTFLAGS disagree
    /// with the target it builds, and a native target-cpu are all named;
    /// a job that matches is not.
    #[test]
    fn target_flags_are_checked_in_matrix_rows_and_jobs() {
        let text = "jobs:\n  build:\n    strategy:\n      matrix:\n        include:\n          - target: x86_64-pc-windows-msvc\n            rustflags: \"-C target-cpu=x86-64-v2\"\n  preview:\n    env:\n      RUSTFLAGS: \"-C target-cpu=native\"\n    steps:\n      - run: cargo build --target x86_64-pc-windows-msvc\n  good:\n    env:\n      RUSTFLAGS: \"-C target-cpu=x86-64-v3\"\n    steps:\n      - run: cargo build --target x86_64-pc-windows-msvc\n";
        let issues = check_targets(&manifest(), &[workflow("w.yml", text)]).expect("regex");
        assert_eq!(issues.len(), 3, "{issues:?}");
        assert!(
            issues.iter().any(|line| line.contains("matrix row")),
            "the matrix row finding is present: {issues:?}"
        );
        assert!(
            issues.iter().any(|line| line.contains("job `preview`")),
            "the job finding is present: {issues:?}"
        );
        assert!(
            issues.iter().any(|line| line.contains("target-cpu=native")),
            "the native target-cpu finding is present: {issues:?}"
        );
    }

    /// A profile the nextest config lacks is named once per workflow.
    #[test]
    fn an_unknown_nextest_profile_is_named_once() {
        let profiles: BTreeSet<String> = core::iter::once(String::from("ci")).collect();
        let text = "run: cargo nextest run --profile ci
run: cargo nextest run \\
  --profile gone
run: cargo nextest run --profile gone
rustup toolchain install nightly --profile minimal
";
        let issues = check_profiles(&profiles, &[workflow("w.yml", text)]).expect("regex");
        assert_eq!(issues.len(), 1, "{issues:?}");
        assert!(
            issues.first().is_some_and(|line| line.contains("gone")),
            "the finding names the missing profile: {issues:?}"
        );
    }
}
