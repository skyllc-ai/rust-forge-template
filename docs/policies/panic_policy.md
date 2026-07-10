# ACMEX Panic Policy

ACMEX enforces a **strict no-panic posture in production code** via
workspace-wide Clippy lints.  This document is the project's
**panic contract**: it codifies *when* a panic / `unwrap` / `expect`
is acceptable, *what shape* it must take, and *how* a contributor
justifies one inline.

The companion doc [`lint-posture.md`](lint-posture.md) covers the
broader lint configuration (rustfmt, rustc, clippy, rustdoc).  This
file zooms in on the panic-family rules - they are strict enough that
they deserve their own contract.

> **Provenance note.** This policy was extracted from a donor project
> (a Windows NTFS file-search tool).  The rules, categories, and
> annotation shapes apply to this workspace as-is; worked examples,
> per-crate posture tables, and decisions-log entries that name donor
> crates are kept as **illustrative donor examples** of what a mature
> project's version of this document grows into.

---

## 1  The rule

Stated as a one-liner contributors can quote:

> **Library code never panics on user input or environment failure.
> Binaries may panic during bootstrap.  Every other `panic!` /
> `unwrap()` / `expect()` in production code is a bug.**

The rule is enforced mechanically by three workspace Clippy lints at
`deny` level in the root `Cargo.toml`:

```toml
[workspace.lints.clippy]
unwrap_used = "deny"                # Force proper error handling
expect_used = "deny"                # Force proper error handling
panic       = "deny"                # No panics allowed
todo        = "deny"                # No TODOs in production code
unimplemented = "deny"              # No unimplemented code
unreachable = "deny"                # No unreachable code
```

Test code is exempt - see
[`clippy.toml`](../../clippy.toml) `allow-*-in-tests = true`.
This split is described in
[`lint-posture.md` §4](lint-posture.md).

Release builds also set `panic = "abort"` in
`[profile.release]` so any escaping panic terminates the process
immediately rather than unwinding - see the root `Cargo.toml`
`[profile.release]` block.

---

## 2  The five categories

Every prod `unwrap` / `expect` / `panic!` in the workspace must fit
exactly one of these five categories.  This taxonomy is the
authoritative classification rule (established during the donor
project's error-handling audit).

| # | Category | Example | Required treatment |
|---|---|---|---|
| **A** | Invariant violation IS a bug - the condition cannot hold at this point given upstream checks | `vec.last()` immediately after `vec.push(x)` | Keep as `expect("invariant: <specific condition>")` with `#[expect(clippy::expect_used, reason = "<invariant + why upstream check guarantees it>")]` annotation |
| **B** | Caller error / validation failure - the value came from user input or wire data and may be ill-formed | `parse_u64(cli_arg)` | Convert to typed error variant; propagate via `?` |
| **C** | Environmental - IO, filesystem, mutex poisoning, syscall failure | `File::open(path)` | Propagate via `?` after `map_err` to a typed error variant; preserve the source via `#[from]` or `#[source]` |
| **D** | Bootstrap - one-time process startup where crash IS the correct failure mode (binary main, daemon initialisation, validated CLI args) | Loading the cache encryption key at daemon start | Keep as `expect` with `"BOOT INVARIANT: <condition>"` prefix; document the failure mode in the surrounding doc comment |
| **E** | Programmer bug at use site - exhaustive `match` arm that the compiler can't prove unreachable, deliberate trap for impossible state | `match Direction { N \| S \| E \| W => …, _ => panic!("impossible direction") }` | Keep as `panic!` with documented invariant in the enclosing function's doc comment; consider `#[track_caller]` |

If a candidate site fits no category, it is **not** acceptable - it
must be converted to either a typed error (B/C) or restructured so
that the impossible state cannot be constructed.

---

## 3  Required annotation shapes

### 3.1  Per-site `#[expect]` template

Every category-A / category-D site must carry a `#[expect]` attribute
with a `reason` that names the invariant:

```rust
// Category A - upstream check guarantees the inner value
#[expect(
    clippy::expect_used,
    reason = "invariant: every Drive entered the registry via DriveLetter::parse, so unwrapping the cached letter cannot fail"
)]
let letter = registry.letter.expect("invariant: parsed at registry insertion");
```

```rust
// Category D - bootstrap path, crash is correct
#[expect(
    clippy::expect_used,
    reason = "BOOT INVARIANT: daemon cannot serve without an encryption key - fail fast at startup"
)]
let key = keystore::load_or_create().expect("BOOT INVARIANT: keystore required at daemon start");
```

The `reason = "…"` text must:

1. Begin with `"invariant:"` (category A) or `"BOOT INVARIANT:"`
   (category D).
2. Name the **specific** upstream condition that makes the panic
   unreachable, not a generic claim like `"should not fail"`.
3. Be on a single string literal (the line may wrap inside the
   `#[expect(...)]`).

The `clippy::missing_expect_message` lint (already `deny` at
workspace level) keeps the `.expect("…")` message itself from being
empty or a `?`-style placeholder.

### 3.2  Per-site `#[expect]` for raw `panic!`

Category-E sites use `panic!` (not `expect`).  The annotation moves
to the enclosing function's doc comment as a `# Panics` section -
required by `clippy::missing_panics_doc = "deny"`:

```rust
/// Returns the next direction in the rotation cycle.
///
/// # Panics
///
/// Panics on category-E unreachable state.  The `match` is
/// exhaustive over `Direction`'s four variants; the wildcard arm
/// is a compile-time trap for future variants added without
/// updating this rotation table.
pub fn rotate(d: Direction) -> Direction { ... }
```

### 3.3  Module-level `#![expect]` (sparing use only)

When **≥ 5 sites in the same module** share an invariant family
(e.g. on-disk-format invariants in a binary-format parser), the
per-site annotations become diff noise.  In that case, place a
module-level attribute at the top of the file with a single broad
reason.  Example from the donor project (an NTFS parser module):

```rust
#![expect(
    clippy::expect_used,
    reason = "NTFS-spec invariants: every expect in this module fires only when a parser encounters a structure that violates the NTFS on-disk spec verified by upstream bounds checks. The parser must propagate up; a corrupt MFT is a user-visible error mode handled at the volume boundary."
)]
```

Module-level `#![expect]` is the **exception**, not the rule.  Add it
only when the per-site cost dominates the per-site signal.  The
default remains per-site annotations.

---

## 4  Per-crate posture summary

The template skeleton's posture is simple: `acmex-version` and
`acmex-core` are library crates (typed errors only, zero prod panics);
`acmex-cli` and the CI tool crates are binaries (`main()` translates
errors into an `ExitCode` / `anyhow::Result` boundary, with category-D
`expect()`s on validated startup state only).

The table below is the **donor project's** per-crate posture, kept as
an illustrative example of what this section should grow into as your
workspace gains crates:

| Crate | Layer | Posture | Justification |
|---|---|---|---|
| `acmex-broker-protocol` | 0 (foundation) | Pure typed errors via `BrokerProtocolError`; zero prod panics expected | Wire-protocol parser - must propagate all malformed input |
| `acmex-text`, `acmex-time` | 0 | Pure types; deterministic transforms; panics only in `const fn` overflow-checks | Mathematically total functions |
| `acmex-security` | 0 | Typed errors (`KeystoreError`, `SealError`); category-D bootstrap panics at OS-keychain init | Win32 / Keychain syscalls have documented postconditions |
| `acmex-mft` | 1 | Typed errors (`MftError`, `#[non_exhaustive]` post-Phase-5c); category-A unwraps on NTFS-spec invariants after upstream bounds checks | NTFS parser - invariants are bytes-on-disk; bugs are user-visible parse failures |
| `acmex-polars` | 1 | Pure adapter; no panics | Wraps polars; surfaces polars errors typed |
| `acmex-core` | 2 | Typed errors (`CoreError`, `LoadCacheError`, `AggregateError`, `ParseAggSpecError`, etc., all `#[non_exhaustive]` post-Phase-5c/5d); zero `Result<_, String>` post-5d | Search / aggregation engine - library-grade typed surface |
| `acmex-client` | 3 | Typed errors (`ClientError`, `CliArgsError`, `ParseSizeError`, all `#[non_exhaustive]` post-Phase-5d) | CLI-argument parser + JSON-RPC client; every error is operator-visible |
| `acmex-mcp` | 3 | Typed errors (`BridgeError`, `#[non_exhaustive]` post-Phase-5c) | MCP bridge - protocol surface |
| `acmex-daemon` | 4 | Typed errors at every internal boundary (`WireSpecError`, `ParseSearchParamsError`, `ConfigError`, all `#[non_exhaustive]` post-Phase-5c/5d); `anyhow::Result` only at the top-level `main`-equivalent boundary | Application aggregator - playbook §739-751 |
| `acmex-cli`, `acmexd`, `acmexmcp` | 5 (binaries) | `anyhow::Result` at `main()`; category-D `expect()`s on validated startup config; everything else propagates | Top-of-stack application binaries |

The single-source-of-truth invariant: **library crates do not return
`anyhow::Error` from public APIs**.  The lint gates enforce this; see
[`lint-posture.md` §3](lint-posture.md) for the audit infrastructure.

---

## 5  Anti-patterns

### 5.1  `unwrap_or_else(|_| panic!(...))`

```rust
// BAD - circumvents `clippy::unwrap_used` and `clippy::panic` via cosmetic detour
let v = parse(input).unwrap_or_else(|_| panic!("parse failed"));
```

The lint set treats this as a panic.  It is not.  Use category B/C
typed-error propagation.

### 5.2  `expect("should not fail")`

```rust
// BAD - generic reason; tells reviewer nothing about the invariant
#[expect(clippy::expect_used, reason = "should not fail")]
let x = thing.expect("should not fail");
```

The `reason = "…"` is read by every reviewer of every future PR
that touches the surrounding code.  Generic text wastes that
review budget.

### 5.3  Source-erasing `From` impl

```rust
// BAD - io::Error source chain is lost
impl From<io::Error> for MyError {
    fn from(e: io::Error) -> Self { MyError::Io(e.to_string()) }
}

// GOOD - source preserved; callers can walk Error::source()
#[derive(thiserror::Error, Debug)]
#[non_exhaustive]
enum MyError {
    #[error("IO failure")]
    Io(#[from] io::Error),
}
```

Phase 5d / 5b audits already enforced this across the workspace; new
code must follow.

### 5.4  `Result<T, String>` in library public API

Banned workspace-wide after Phase 5d.  `Result<T, String>` cannot be
introspected, cannot chain via `Error::source()`, and forces stringly-
typed downstream handling.  Use a typed `thiserror::Error` enum with
`#[non_exhaustive]`.

---

## 6  Audit infrastructure

The donor project maintained a strict-clippy-driven counter
(`risk_markers_prod.sh`) that used
`cargo clippy --message-format=json` to extract `unwrap_used` /
`expect_used` / `panic` diagnostic spans, excluding test mode.  This
template does not ship the script; the equivalent ad-hoc audit is:

```bash
cargo clippy --workspace --all-targets --message-format=json \
  | jq -r 'select(.reason == "compiler-message")
           | .message.code.code // empty' \
  | grep -c 'unwrap_used\|expect_used\|clippy::panic' || true
```

A clippy-JSON-based count is the **authoritative** prod-only
inventory; naive file-scoped `rg` counts overcount heavily because
they include `#[cfg(test)]` modules.

### 6.1  Workspace cross-references

Every site that touches the panic policy must cross-reference the
others to keep the contract auditable:

- `Cargo.toml` `[workspace.lints.clippy]` carries a doc comment
  pointing at this file.
- `clippy.toml` carries a doc comment pointing at this file and at
  `lint-posture.md`.
- `docs/CONTRIBUTING.md §Panic policy` summarises the rule and links here.
- `lint-posture.md §4` covers the broader test-vs-prod split.

---

## 7  Decisions log

This section is append-only.  Add new rows above the divider; do not
edit existing rows (they document the *evolution* of the policy).
The rows below are inherited donor-project history, kept as a worked
example of the log format - reset the table when you adopt this
template.

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-12 | `panic = "deny"` / `unwrap_used = "deny"` / `expect_used = "deny"` adopted as workspace-wide defaults | Pre-Phase-5 baseline; strict-gate posture established before the per-crate audit started |
| 2026-05-18 | `#[non_exhaustive]` added to every library-crate error enum (Phase 5c, PR #268) | Unblocks future variant additions without a semver bump |
| 2026-05-18 | `Result<_, String>` migration complete across `acmex-cli` / `acmex-daemon` / `acmex-client` / `acmex-core` (Phase 5d, PR #277) | All 32 audit sites converted to typed enums with `Error::source` chaining and byte-identical Display strings |
| 2026-05-18 | This document created (Phase 5e) | Codifies the five-category decision tree and per-site annotation contract for future contributors |

---

## 8  See also

- [`lint-posture.md`](lint-posture.md) - full lint configuration
  (rustfmt, rustc, clippy, rustdoc, cargo-deny)
- [`../../SECURITY.md`](../../SECURITY.md) - cargo-deny + cargo-vet
  supply-chain posture
- Root `Cargo.toml` - `[workspace.lints]` source of truth
- Root `clippy.toml` - clippy configuration source of truth
