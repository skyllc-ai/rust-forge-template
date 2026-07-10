// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright (c) 2026 Acmex Placeholder LLC

//! One-shot init ceremony for a repository created from rust-forge-template.
//!
//! Rewrites the placeholder identity (`acmex` / `Acmex` / `ACMEX`,
//! `acmex-org`, `acmex-owner`, `Acmex Placeholder LLC`, `acmex.example`)
//! to the new project's identity, renames files and directories, refreshes
//! the lockfile, regenerates the git hooks from the gate manifest, and
//! asserts that zero placeholder references survive. On success it removes
//! itself (`tools/init`).
//!
//! Usage (via the `just init` recipe):
//!
//! ```text
//! just init myproj my-org "My Org LLC" "Me <me@example.com>"
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

/// Directories never touched by the ceremony.
const SKIP_DIRS: &[&str] = &[".git", "target", "tools"];

/// Every project born from the template starts at the Cargo convention.
/// The TEMPLATE's own version keeps moving (it ships its own releases);
/// yours begins fresh here.
const NEW_PROJECT_VERSION: &str = "0.1.0";

/// The ceremony's parsed inputs.
struct Identity {
    /// Crate/binary prefix and repo slug, e.g. `myproj`. Lowercase.
    slug: String,
    /// GitHub org/user owning the new repo, e.g. `my-org`.
    org: String,
    /// Legal entity for SPDX copyright lines.
    entity: String,
    /// Author line for Cargo manifests, `Name <email>`.
    author: String,
    /// Domain used in contact addresses (default `<org>.example`).
    domain: String,
    /// SPDX license expression (default keeps the template's
    /// `MIT OR Apache-2.0`). A custom value rewrites every SPDX header,
    /// Cargo.toml, REUSE.toml, and the LICENSE pointer; the `reuse` gate
    /// then stays red until LICENSES/ holds the matching text(s).
    license: String,
}

/// The template's shipped license expression.
const DEFAULT_LICENSE: &str = "MIT OR Apache-2.0";

fn parse_args() -> Result<Identity, String> {
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let key = arg
            .strip_prefix("--")
            .ok_or_else(|| format!("unexpected argument `{arg}` (expected --key value)"))?
            .to_string();
        let value = args.next().ok_or_else(|| format!("--{key} needs a value"))?;
        values.insert(key, value);
    }
    let slug = values
        .get("name")
        .ok_or("--name <slug> is required (lowercase, [a-z][a-z0-9-]*)")?
        .clone();
    if !slug
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-')
        || !slug.starts_with(|ch: char| ch.is_ascii_lowercase())
    {
        return Err(format!(
            "--name `{slug}` must be lowercase and match [a-z][a-z0-9-]*"
        ));
    }
    let org = values.get("org").ok_or("--org <github-org> is required")?.clone();
    let entity = values
        .get("entity")
        .cloned()
        .unwrap_or_else(|| format!("{org} contributors"));
    let author = values
        .get("author")
        .cloned()
        .unwrap_or_else(|| format!("{org} <dev@{org}.example>"));
    let domain = values
        .get("domain")
        .cloned()
        .unwrap_or_else(|| format!("{org}.example"));
    let license = values
        .get("license")
        .cloned()
        .unwrap_or_else(|| DEFAULT_LICENSE.to_string());
    Ok(Identity {
        slug,
        org,
        entity,
        author,
        domain,
        license,
    })
}

/// Ordered replacement table: most specific first so compound placeholders
/// rewrite before the bare slug.
fn replacements(id: &Identity) -> Vec<(String, String)> {
    let capitalized = {
        let mut chars = id.slug.chars();
        match chars.next() {
            Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
            None => String::new(),
        }
    };
    let upper = id.slug.to_ascii_uppercase();
    let mut table = vec![
        (
            "Acmex Placeholder Dev <dev@acmex.example>".to_string(),
            id.author.clone(),
        ),
        ("Acmex Placeholder LLC".to_string(), id.entity.clone()),
        ("acmex.example".to_string(), id.domain.clone()),
        ("acmex-org".to_string(), id.org.clone()),
        ("acmex-owner".to_string(), id.org.clone()),
        ("AcmexOrg.Acmex".to_string(), format!("{}.{capitalized}", capitalized_org(&id.org))),
        ("ACMEX".to_string(), upper),
        ("Acmex".to_string(), capitalized),
        ("acmex".to_string(), id.slug.clone()),
    ];
    if id.license != DEFAULT_LICENSE {
        table.push((DEFAULT_LICENSE.to_string(), id.license.clone()));
    }
    table
}

/// Winget-style capitalized org segment (`my-org` -> `MyOrg`).
fn capitalized_org(org: &str) -> String {
    org.split(['-', '_'])
        .map(|segment| {
            let mut chars = segment.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

/// Recursively collects every file under `dir`, skipping SKIP_DIRS roots.
fn collect_files(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if entry.file_type()?.is_dir() {
            if dir == Path::new(".") && SKIP_DIRS.contains(&name.as_ref()) {
                continue;
            }
            collect_files(&path, out)?;
        } else {
            out.push(path);
        }
    }
    Ok(())
}

/// Applies the replacement table to one file's content (UTF-8 text only;
/// binary files are left untouched).
fn rewrite_file(path: &Path, table: &[(String, String)]) -> std::io::Result<bool> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Ok(false); // non-UTF-8: binary asset, skip
    };
    let mut rewritten = content.clone();
    for (from, to) in table {
        rewritten = rewritten.replace(from, to);
    }
    if rewritten == content {
        return Ok(false);
    }
    std::fs::write(path, rewritten)?;
    Ok(true)
}

/// Renames every path containing the placeholder slug, deepest first.
fn rename_paths(slug: &str) -> std::io::Result<usize> {
    let mut renamed = 0;
    loop {
        let mut paths = Vec::new();
        collect_dirs_and_files(Path::new("."), &mut paths)?;
        // Deepest first so parents stay valid while children move.
        paths.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        let mut changed = false;
        for path in paths {
            let Some(name) = path.file_name().map(|name| name.to_string_lossy().to_string()) else {
                continue;
            };
            if name.contains("acmex") {
                let new_name = name.replace("acmex", slug);
                let new_path = path.with_file_name(new_name);
                std::fs::rename(&path, &new_path)?;
                renamed += 1;
                changed = true;
            }
        }
        if !changed {
            return Ok(renamed);
        }
    }
}

/// Recursively collects files AND directories (for renaming).
fn collect_dirs_and_files(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if entry.file_type()?.is_dir() {
            if dir == Path::new(".") && SKIP_DIRS.contains(&name.as_ref()) {
                continue;
            }
            collect_dirs_and_files(&path, out)?;
        }
        out.push(path);
    }
    Ok(())
}

/// Runs a command, returning an error on non-zero exit.
fn run(program: &str, args: &[&str]) -> Result<(), String> {
    println!("  $ {program} {}", args.join(" "));
    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|error| format!("failed to spawn {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("`{program} {}` failed ({status})", args.join(" ")))
    }
}

/// Asserts zero placeholder references survive (the ceremony's acid test).
fn assert_clean(table_slug: &str) -> Result<(), String> {
    let mut files = Vec::new();
    collect_files(Path::new("."), &mut files).map_err(|error| error.to_string())?;
    let mut dirty = Vec::new();
    for path in &files {
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.contains("acmex") || content.contains("Acmex") || content.contains("ACMEX")
            {
                dirty.push(path.display().to_string());
            }
        }
    }
    if dirty.is_empty() {
        println!("✅ zero placeholder references remain (renamed to `{table_slug}`)");
        Ok(())
    } else {
        Err(format!(
            "placeholder references survived in: {}",
            dirty.join(", ")
        ))
    }
}

/// Rewrites the workspace version (and the matching internal-dependency
/// pins) from whatever the template shipped at to [`NEW_PROJECT_VERSION`].
fn reset_version() -> Result<(), String> {
    let manifest_path = Path::new("Cargo.toml");
    let manifest = std::fs::read_to_string(manifest_path).map_err(|error| error.to_string())?;
    let current = manifest
        .lines()
        .find_map(|line| line.trim().strip_prefix("version = \""))
        .and_then(|rest| rest.split('"').next())
        .ok_or("could not find `version = \"...\"` in Cargo.toml")?
        .to_string();
    if current == NEW_PROJECT_VERSION {
        println!("🔢 version already {NEW_PROJECT_VERSION}");
        return Ok(());
    }
    let updated = manifest.replace(
        &format!("version = \"{current}\""),
        &format!("version = \"{NEW_PROJECT_VERSION}\""),
    );
    std::fs::write(manifest_path, updated).map_err(|error| error.to_string())?;
    println!("🔢 version reset: {current} -> {NEW_PROJECT_VERSION}");
    Ok(())
}

/// Replaces the inherited CHANGELOG (the template's release history) with a
/// fresh Keep-a-Changelog skeleton for the new project.
fn reset_changelog(id: &Identity) -> Result<(), String> {
    // REUSE-IgnoreStart -- the SPDX line below is CONTENT for the generated
    // CHANGELOG, not this file's own license metadata.
    let lines = [
        "<!--".to_string(),
        "SPDX-License-Identifier: MIT OR Apache-2.0".to_string(),
        format!("Copyright (c) 2026 {}", id.entity),
        "-->".to_string(),
        String::new(),
        "# Changelog".to_string(),
        String::new(),
        "All notable changes to this project will be documented in this file.".to_string(),
        String::new(),
        "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),".to_string(),
        "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
            .to_string(),
        String::new(),
        "## [Unreleased]".to_string(),
        String::new(),
    ];
    // REUSE-IgnoreEnd
    let skeleton = lines.join("\n");
    std::fs::write("CHANGELOG.md", skeleton).map_err(|error| error.to_string())?;
    println!("📄 CHANGELOG reset to a fresh skeleton");
    Ok(())
}

fn ceremony() -> Result<(), String> {
    let id = parse_args()?;
    println!("🔧 init ceremony: acmex -> {}", id.slug);

    // Refuse to run twice.
    if !Path::new("crates/acmex-core").exists() {
        return Err("crates/acmex-core not found - already initialized?".to_string());
    }

    // 1. Content rewrite.
    let table = replacements(&id);
    let mut files = Vec::new();
    collect_files(Path::new("."), &mut files).map_err(|error| error.to_string())?;
    let mut rewritten = 0;
    for path in &files {
        if rewrite_file(path, &table).map_err(|error| format!("{}: {error}", path.display()))? {
            rewritten += 1;
        }
    }
    println!("✍️  rewrote {rewritten} files");

    // 2. Path renames.
    let renamed = rename_paths(&id.slug).map_err(|error| error.to_string())?;
    println!("📁 renamed {renamed} paths");

    // 2b. Version reset: the template's own release version must not leak
    //     into new projects - every project starts at 0.1.0.
    reset_version()?;

    // 2c. Changelog reset: the template's release history is not yours.
    reset_changelog(&id)?;

    // 3. Refresh the lockfile for the renamed internal packages.
    run("cargo", &["update", "--workspace"])?;

    // 4. Regenerate the hooks from the gate manifest (paranoia: the rename
    //    rewrote both sides identically, but regeneration is the contract).
    // 3b. Format the renamed tree: the rename reflows generated code, and
    //     the pre-commit fmt gate would otherwise reject the init commit.
    run("cargo", &["fmt", "--all"])?;

    let gen_hooks = format!("{}-gen-hooks", id.slug);
    run("cargo", &["run", "-q", "-p", &gen_hooks, "--", "--target", "pre-push"])?;
    run("cargo", &["run", "-q", "-p", &gen_hooks, "--", "--target", "pre-commit"])?;

    // 5. Acid test.
    assert_clean(&id.slug)?;

    // 5b. Custom license: the identifiers are rewritten, but the license
    //     TEXTS are the user's job - and the reuse gate enforces it.
    if id.license != DEFAULT_LICENSE {
        println!();
        println!("⚖️  license set to `{}` - finish the relicense:", id.license);
        println!("   * add LICENSES/<id>.txt for each id in the expression");
        println!("     (texts: https://spdx.org/licenses/) and remove the");
        println!("     MIT/Apache-2.0 texts if no longer used");
        println!("   * rewrite the LICENSE pointer file's prose");
        println!("   * `reuse lint` (part of every commit) stays red until done");
    }

    // 6. Self-delete (best effort; on failure print the manual step).
    match std::fs::remove_dir_all("tools/init") {
        Ok(()) => println!("🧹 removed tools/init"),
        Err(error) => println!("⚠️  could not remove tools/init ({error}) - delete it manually"),
    }

    println!();
    println!("🎉 {} is ready. Next steps:", id.slug);
    println!("   1. just install-hooks");
    println!("   2. just go");
    println!("   3. bash scripts/ci/bootstrap-github.sh   (rulesets, labels, lane variables)");
    println!("   4. git add -A && git commit -m 'chore: init {} from rust-forge-template'", id.slug);
    println!();
    println!("   Review README.md for the stable-downgrade appendix and docs/forge/COMPONENTS.md");
    println!("   for enabling dormant lanes (release, crates.io, winget, ...).");
    Ok(())
}

fn main() -> ExitCode {
    match ceremony() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("init: error: {message}");
            ExitCode::FAILURE
        }
    }
}
