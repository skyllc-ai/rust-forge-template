// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! End-to-end integration tests for the `acmex` binary.
//!
//! Spawns the real compiled binary via [`assert_cmd`] so the full
//! parse → validate → render → exit-code path is exercised exactly as a
//! user would hit it.

#![expect(
    unused_crate_dependencies,
    reason = "integration test - links the package's library deps it does not use"
)]

#[cfg(test)]
mod tests {
    use assert_cmd::Command;

    /// `acmex` with no arguments greets the world and exits 0.
    #[test]
    fn default_invocation_greets_world() {
        let mut command = Command::cargo_bin("acmex").expect("binary builds");
        command.assert().success().stdout("Hello, world!\n");
    }

    /// `acmex <name>` greets the given recipient.
    #[test]
    fn named_invocation_greets_recipient() {
        let mut command = Command::cargo_bin("acmex").expect("binary builds");
        command
            .arg("Ada")
            .assert()
            .success()
            .stdout("Hello, Ada!\n");
    }

    /// A blank recipient fails with a non-zero exit code and an error on
    /// stderr.
    #[test]
    fn blank_recipient_fails_with_error() {
        let mut command = Command::cargo_bin("acmex").expect("binary builds");
        let output = command.arg("   ").output().expect("binary runs");
        assert!(!output.status.success());
        let stderr = String::from_utf8(output.stderr).expect("stderr is utf8");
        assert!(
            stderr.contains("recipient"),
            "stderr should name the invalid field: {stderr}"
        );
    }

    /// `--version` as the first argument prints the version banner.
    #[test]
    fn version_flag_prints_banner() {
        let mut command = Command::cargo_bin("acmex").expect("binary builds");
        let output = command.arg("--version").output().expect("binary runs");
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).expect("stdout is utf8");
        assert!(
            stdout.starts_with("acmex "),
            "version banner should start with the binary name: {stdout}"
        );
    }
}
