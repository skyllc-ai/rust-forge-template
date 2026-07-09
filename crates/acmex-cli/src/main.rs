// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! # acmex: skeleton CLI for the acmex workspace
//!
//! Template placeholder binary.  Parses a recipient name, builds a validated
//! [`acmex_core::Greeting`], and prints it.  Replace the greeting flow with
//! real subcommands; keep the conventions it demonstrates:
//!
//! - `acmex_version::handle_version!` as the first statement of `main`
//!   (consistent `--version` / `--version -v` across every workspace binary)
//! - output written through an injected [`std::io::Write`] handle so the
//!   rendering logic is unit-testable without spawning the binary
//! - process exit codes via [`std::process::ExitCode`], never `panic!`

use std::process::ExitCode;

use acmex_core::Greeting;
// Dev-dependency anchor: `assert_cmd` is only used by `tests/cli.rs`, but the
// unit-test build of this binary links every dev-dependency, so the
// `unused_crate_dependencies` lint needs this cfg(test)-scoped anchor.
#[cfg(test)]
use assert_cmd as _;
use clap::Parser;

/// Command-line arguments for the `acmex` skeleton binary.
#[derive(Debug, Parser)]
#[command(name = "acmex", about = "acmex — template placeholder CLI", version)]
struct Cli {
    /// Recipient to greet.
    #[arg(default_value = "world")]
    recipient: String,
}

/// Renders the greeting for the parsed arguments into `writer`.
///
/// Split out of `main` so the logic is testable with an in-memory writer.
fn run<W: std::io::Write>(cli: &Cli, writer: &mut W) -> Result<(), String> {
    let greeting =
        Greeting::new(&cli.recipient).map_err(|greeting_error| greeting_error.to_string())?;
    writeln!(writer, "{}", greeting.message()).map_err(|io_error| io_error.to_string())
}

/// CLI entry point: version banner, parse, run, translate to an exit code.
#[expect(
    clippy::print_stderr,
    reason = "operational CLI binary — the final error report goes to stderr; \
              all other output flows through the injected writer in `run`"
)]
fn main() -> ExitCode {
    acmex_version::handle_version!("acmex");
    let cli = Cli::parse();
    match run(&cli, &mut std::io::stdout()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("acmex: error: {message}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser as _;

    use super::{Cli, run};

    /// The default invocation greets the world.
    #[test]
    fn default_recipient_is_world() {
        let cli = Cli::parse_from(["acmex"]);
        let mut output: Vec<u8> = Vec::new();
        run(&cli, &mut output).expect("greeting succeeds");
        assert_eq!(String::from_utf8(output).expect("utf8"), "Hello, world!\n");
    }

    /// An explicit recipient is validated and rendered.
    #[test]
    fn explicit_recipient_is_greeted() {
        let cli = Cli::parse_from(["acmex", "Ada"]);
        let mut output: Vec<u8> = Vec::new();
        run(&cli, &mut output).expect("greeting succeeds");
        assert_eq!(String::from_utf8(output).expect("utf8"), "Hello, Ada!\n");
    }

    /// A whitespace-only recipient is rejected with a domain error.
    #[test]
    fn blank_recipient_fails() {
        let cli = Cli::parse_from(["acmex", "   "]);
        let mut output: Vec<u8> = Vec::new();
        let result = run(&cli, &mut output);
        assert!(result.is_err());
        assert!(output.is_empty());
    }
}
