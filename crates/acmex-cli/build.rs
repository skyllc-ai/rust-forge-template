// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! Build script for `acmex-cli` (the `acmex` binary).
//!
//! Stamps the git sha + build metadata (`ACMEX_GIT_SHA`, `ACMEX_RUSTC`,
//! `ACMEX_TARGET`, `ACMEX_PROFILE`, ...) that the `acmex-version` macros
//! read at compile time, so `acmex --version -v` prints an accurate build
//! fingerprint.
//!
//! Projects that want Windows resource embedding (icon, version info,
//! app.manifest) add `winresource` here — see the donor pattern in the
//! template documentation.

fn main() {
    acmex_version::emit_build_env();
    println!("cargo:rerun-if-changed=build.rs");
}
