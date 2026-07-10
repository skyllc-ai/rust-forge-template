// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! Build script: stamps git sha + build metadata for the `acmex-version`
//! macros (`ACMEX_GIT_SHA`, `ACMEX_RUSTC`, `ACMEX_TARGET`, `ACMEX_PROFILE`).
//!
//! Projects that want Windows resource embedding (icon, version info,
//! app.manifest) add `winresource` here - see the template documentation.

fn main() {
    acmex_version::emit_build_env();
    println!("cargo:rerun-if-changed=build.rs");
}
