// SPDX-License-Identifier: MPL-2.0
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
//! - an error type implementing [`core::error::Error`] by hand or via
//!   `thiserror` (add it through `[workspace.dependencies]`)
//! - unit tests plus at least one doc-test per public API
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

use core::fmt;

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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum GreetingError {
    /// The recipient was empty or whitespace-only after trimming.
    EmptyRecipient,
}

impl fmt::Display for GreetingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyRecipient => {
                write!(
                    f,
                    "recipient must contain at least one non-whitespace character"
                )
            }
        }
    }
}

impl core::error::Error for GreetingError {}

#[cfg(test)]
mod tests {
    use super::{Greeting, GreetingError};

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
