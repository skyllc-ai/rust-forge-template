// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! Commit-time code classification uses the manifest's existing path
//! patterns, so a `gate_when = "code_changed"` gate can run at
//! pre-commit (staged-scoped) with the same meaning it has at pre-push
//! (range-scoped): "code" is rust OR dep OR infra, derived from the
//! `[classification]` table, never a second regex to drift.

use crate::manifest::Manifest;

/// The `has_staged_code` helper the pre-commit dispatch calls for every
/// `code_changed` gate.
///
/// No staged files (a manual `just lint-fast` run) or an absent
/// `[classification]` table conservatively runs the gates: a helper
/// that cannot classify must not skip.
pub(super) fn helpers(manifest: &Manifest) -> String {
    let patterns: Option<Vec<&str>> = manifest.classification.as_ref().and_then(|classes| {
        ["rust", "dep", "infra"]
            .iter()
            .map(|name| classes.patterns.get(*name).map(String::as_str))
            .collect()
    });
    let Some(available) = patterns else {
        return String::from("\nhas_staged_code() { return 0; }\n");
    };
    let regex = super::shell_quote(&available.join("|"));
    format!(
        "\nhas_staged_code() {{ ! has_any_staged || printf '%s\\n' \"$STAGED_ALL\" | grep -Eq {regex}; }}\n"
    )
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use super::*;

    /// Execute the generated dispatch with a recording spawn instead of
    /// running the gate command, so the classification can be asserted
    /// against real staged-path shapes.
    #[test]
    fn docs_skip_but_code_dependencies_and_infra_run() {
        let mut manifest: Manifest =
            toml::from_str(include_str!("../../../gates.toml")).expect("real manifest");
        // One synthetic pre-commit gate is enough: the classification
        // helper is what is under test, not the manifest's gate set.
        manifest.gate.clear();
        manifest.gate.push(crate::manifest::Gate {
            id: String::from("code-gate"),
            label: String::from("x"),
            command: vec![String::from("true")],
            tiers: vec![String::from("pre-commit")],
            when: String::from("code_changed"),
            hard: true,
            tool: String::from("bash"),
            expected_runtime_secs: 1,
            bucket: Some(String::from("bg")),
            order: 1,
            consumer_names: alloc::collections::BTreeMap::new(),
            notes: String::new(),
        });
        let script = format!(
            "has_any_staged() {{ [[ -n \"$STAGED_ALL\" ]]; }}\nspawn() {{ printf '%s' \"$1\"; }}\n{}{}",
            helpers(&manifest),
            super::super::render_dispatch_fast(&manifest),
        );
        for (paths, runs) in [
            ("docs/forge/COMPONENTS.md\nREADME.md", false),
            ("crates/acmex-core/src/lib.rs", true),
            ("Cargo.lock", true),
            ("crates/acmex-core/Cargo.toml", true),
            ("scripts/ci/gates.toml", true),
            ("README.md\ncrates/acmex-core/src/lib.rs", true),
            ("", true),
        ] {
            let output = Command::new("bash")
                .args(["-c", &script])
                .env("STAGED_ALL", paths)
                .output()
                .expect("bash fixture");
            assert_eq!(
                String::from_utf8_lossy(&output.stdout),
                if runs { "code-gate" } else { "" },
                "{paths}"
            );
        }
        assert!(
            super::super::PREAMBLE_PRE_COMMIT.contains("--diff-filter=ACMRD"),
            "deletions must also be classified"
        );
    }
}
