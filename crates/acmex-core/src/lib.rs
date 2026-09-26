// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! # acmex-core: skeleton library for the acmex workspace
//!
//! Template placeholder crate.  It exists to exercise the full quality
//! machinery (lints, tests, doc-tests, rustdoc, coverage) with a minimal
//! but honest surface: a validated [`Greeting`] value type and its
//! [`GreetingError`].  Replace this module with real domain logic; keep
//! the conventions it demonstrates:
//!
//! - crate-level docs with a scope statement (this header)
//! - a fallible constructor returning a domain error (never `panic!`)
//! - an error type deriving [`core::error::Error`] via `thiserror` (inherited
//!   from `[workspace.dependencies]`)
//! - unit tests, a table-driven invariants test, and at least one doc-test per
//!   public API
//!
//! ## Scope
//!
//! Pure logic, no I/O, no platform dependencies.
//!
//! # Examples
//!
//! ```
//! use acmex_core::Greeting;
//!
//! let greeting = Greeting::new("world").expect("non-empty recipient");
//! assert_eq!(greeting.message(), "Hello, world!");
//! ```

// On docs.rs only: enable the `doc_cfg` rustdoc feature so cfg-gated items
// render with their cfg badge.  Local `cargo doc` never passes `--cfg docsrs`,
// so the nightly-only feature is never exercised outside docs.rs builds.
#![cfg_attr(docsrs, feature(doc_cfg))]

use thiserror::Error;

/// A validated greeting for a named recipient.
///
/// Construction goes through [`Greeting::new`], which rejects empty or
/// whitespace-only recipients, so a constructed value is always printable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Greeting {
    /// The validated, trimmed recipient name.
    recipient: String,
}

impl Greeting {
    /// Creates a greeting for `recipient`.
    ///
    /// The recipient is trimmed; an empty or whitespace-only recipient is
    /// rejected with [`GreetingError::EmptyRecipient`].
    ///
    /// # Errors
    ///
    /// Returns [`GreetingError::EmptyRecipient`] when `recipient` contains
    /// no non-whitespace characters.
    ///
    /// # Examples
    ///
    /// ```
    /// use acmex_core::{Greeting, GreetingError};
    ///
    /// assert!(Greeting::new("Ada").is_ok());
    /// assert_eq!(Greeting::new("   "), Err(GreetingError::EmptyRecipient));
    /// ```
    pub fn new(recipient: &str) -> Result<Self, GreetingError> {
        let trimmed = recipient.trim();
        if trimmed.is_empty() {
            return Err(GreetingError::EmptyRecipient);
        }
        Ok(Self {
            recipient: String::from(trimmed),
        })
    }

    /// Renders the greeting message.
    ///
    /// # Examples
    ///
    /// ```
    /// use acmex_core::Greeting;
    ///
    /// let greeting = Greeting::new("Ada").expect("non-empty recipient");
    /// assert_eq!(greeting.message(), "Hello, Ada!");
    /// ```
    #[must_use]
    pub fn message(&self) -> String {
        format!("Hello, {}!", self.recipient)
    }

    /// Returns the validated recipient name.
    #[must_use]
    pub fn recipient(&self) -> &str {
        &self.recipient
    }
}

/// Errors returned by [`Greeting::new`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum GreetingError {
    /// The recipient was empty or whitespace-only after trimming.
    #[error("recipient must contain at least one non-whitespace character")]
    EmptyRecipient,
}

#[cfg(test)]
mod tests {
    use super::{Greeting, GreetingError};

    /// Invariants over a table of edge inputs: a constructed greeting
    /// never carries surrounding whitespace and always renders its
    /// recipient; an input with no non-whitespace character is always
    /// rejected. (A property-based test with `proptest` is the natural
    /// upgrade once the crate has real invariants; it is not pre-declared
    /// in the workspace because its dependency tree must be vetted.)
    #[test]
    fn recipient_invariants_over_edge_inputs() {
        let inputs = [
            "",
            " ",
            "\t\n\r ",
            "\u{a0}\u{2003}",
            "a",
            " a ",
            "\u{2003}Ünïcödé\u{2003}",
            "two words",
            "trailing\t",
            "\nleading",
        ];
        for input in inputs {
            match Greeting::new(input) {
                Ok(greeting) => {
                    let recipient = greeting.recipient();
                    assert_eq!(recipient, input.trim(), "recipient is the trimmed input");
                    assert!(!recipient.is_empty(), "accepted recipient is never empty");
                    assert_eq!(greeting.message(), format!("Hello, {recipient}!"));
                }
                Err(error) => {
                    assert_eq!(error, GreetingError::EmptyRecipient);
                    assert!(
                        input.trim().is_empty(),
                        "rejected input has no visible character: {input:?}"
                    );
                }
            }
        }
    }

    /// A plain recipient round-trips into the rendered message.
    #[test]
    fn message_contains_recipient() {
        let greeting = Greeting::new("Ada").expect("valid recipient");
        assert_eq!(greeting.message(), "Hello, Ada!");
        assert_eq!(greeting.recipient(), "Ada");
    }

    /// Surrounding whitespace is trimmed before validation and rendering.
    #[test]
    fn recipient_is_trimmed() {
        let greeting = Greeting::new("  Grace  ").expect("valid recipient");
        assert_eq!(greeting.message(), "Hello, Grace!");
    }

    /// Empty and whitespace-only recipients are rejected, never rendered.
    #[test]
    fn empty_recipient_is_rejected() {
        assert_eq!(Greeting::new(""), Err(GreetingError::EmptyRecipient));
        assert_eq!(Greeting::new(" \t\n"), Err(GreetingError::EmptyRecipient));
    }

    /// The error type renders a human-readable message via `Display`.
    #[test]
    fn error_display_is_meaningful() {
        let rendered = GreetingError::EmptyRecipient.to_string();
        assert!(rendered.contains("recipient"));
    }
}
