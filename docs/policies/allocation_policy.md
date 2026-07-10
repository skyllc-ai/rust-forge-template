# ACMEX Allocation Policy

ACMEX enforces a **clone-and-allocation discipline in production code** to keep
hot paths predictable.  This document is the project's
**allocation contract**: it codifies *when* a `.clone()`, `format!()`, or
heap-string operation is acceptable, *what shape* it must take, and *how* a
contributor justifies one inline.

The companion docs:
- [`panic_policy.md`](panic_policy.md) - when panics / `unwrap` / `expect` are
  acceptable.
- [`lint-posture.md`](lint-posture.md) - full lint configuration (rustfmt,
  rustc, clippy, rustdoc, cargo-deny).

> **Provenance note.** This policy was extracted from a donor project
> (a Windows NTFS file-search tool).  The rules, categories, and
> annotation shapes apply to this workspace as-is; the worked
> examples and decisions-log entries that cite donor files and PRs
> are kept as **illustrative donor examples** of the contract in
> action.

---

## 1  The rule

Stated as a one-liner contributors can quote:

> **Hot paths (per-record / per-row / per-query) never allocate
> defensively.  Cold paths (error context, log lines, one-time setup)
> may allocate freely.  Every `.clone()` / `format!()` / `to_owned()`
> in production code must fit one of the five blessed categories
> (α / β / γ / δ / ε), and δ is a bug.**

The categories:

| Category | Pattern | Verdict | Notes |
|----------|---------|--------:|-------|
| **α - Arc clone** | `Arc::clone(&x)` / `x.clone()` where `x: Arc<T>` | **KEEP** | Refcount bump for `tokio::spawn`, broadcast channels, fan-out of immutable data |
| **β - Ownership fence** | Caller has `&T` but the called API needs `T` (stores / mutates / consumes) | **KEEP** | The only safe shape given the surrounding ownership graph |
| **γ - Error / log context** | `String` / `PathBuf` carried into an error variant or log line | **KEEP** | Error paths are cold; allocation cost is dominated by the error itself |
| **δ - Hot-path anti-pattern** | Clone of `String` / `Vec<T>` inside a per-record / per-query loop that could be eliminated by restructuring ownership | **FIX** | Refactor the call site; never suppress |
| **ε - Test helper** | `#[cfg(test)]`-only allocation | **KEEP** | Out of scope; test code is exempt from the discipline |

Test code is exempt - see
[`clippy.toml`](../../clippy.toml) `allow-*-in-tests = true`.
This split mirrors the panic-policy test/prod boundary described in
[`panic_policy.md` §1](panic_policy.md) and
[`lint-posture.md` §4](lint-posture.md).

---

## 2  The lint posture

Five workspace Clippy lints at `deny` level (out of 12 clone-family lints
total) enforce the rule mechanically:

```toml
[workspace.lints.clippy]
redundant_clone           = "deny"  # Avoid unnecessary clones
clone_on_ref_ptr          = "deny"  # Use Arc::clone(&x) form (not x.clone())
cloned_instead_of_copied  = "deny"  # Prefer .copied() for Copy types
inefficient_to_string     = "deny"  # Use format!("{}", x) over x.to_string()
unnecessary_to_owned      = "deny"  # Avoid .to_owned() on already-owned types
```

The remaining seven (`implicit_clone`, `map_clone`, `assigning_clones`,
`str_to_string`, `string_to_string`, `iter_overeager_cloned`,
`unnecessary_owned_empty_strings`) sit at `warn` and are upgraded ad hoc
when a new pattern surfaces.

`cargo clippy --workspace --all-targets --message-format=json` emits **zero**
diagnostics for these 12 lints on every commit landing in `main`.  Any new
clone-family diagnostic blocks the pre-push gate.

Release builds also set `opt-level = 3` + `lto = "fat"` (see the root
`Cargo.toml` `[profile.release]`), so the compiler eliminates dead
`.clone()`s the audit might have missed.

---

## 3  The five categories - in depth

### 3.1  Category α - Arc clone

**Pattern:**

```rust
let cb = shared_callback.clone();           // Arc<dyn Fn(...)>
tokio::spawn(async move { run_task(cb).await });
```

**Verdict:** KEEP.

`Arc::clone(&shared_callback)` is an 8-byte atomic refcount bump.  The cost
is roughly equivalent to a function-call prologue and orders of magnitude
cheaper than any structural alternative (channel, mutex, etc.).

**Workspace convention:**
- `clone_on_ref_ptr = "deny"` enforces the explicit `Arc::clone(&x)` form
  for clarity.  `x.clone()` on an `Arc<T>` is a Clippy error.
- Spawned tasks may hold `Arc<T>` for an unbounded duration - the refcount
  decrements when the task drops the captured value.

**Examples from the donor project:**
- a multi-drive reader - `shared_callback.clone()` per spawned
  per-drive worker task.
- a parallel-parse pipeline - `rx.clone()`, `bitmap_arc.clone()` for
  worker channels.
- a daemon pressure watcher - `sender.clone()` for the watcher spawn.

---

### 3.2  Category β - Ownership fence

**Pattern** (example from the donor project - a copy-on-write index
patch):

```rust
fn apply_patch(body_arc: &Arc<Index>, changes: &[Change])
    -> Option<(Arc<Index>, PatchStats)>
{
    // Deep-clone the inner Index so the patch loop mutates the clone -
    // never the live Arc that concurrent readers are observing.
    let mut owned: Index = (**body_arc).clone();
    let stats = apply_changes(&mut owned, changes);
    Some((Arc::new(owned), stats))
}
```

**Verdict:** KEEP.

The caller has a shared reference (`&Arc<T>`).  Producing the new patched
state requires owning a `T`.  Clone is the only safe path - alternatives
(unsafe transmute, atomic CAS on the inner pointer) sacrifice the
copy-on-write semantics that lock-free readers rely on.

**Workspace convention:**
- The reason text must explain *why* the clone is unavoidable (typically
  one of: copy-on-write semantics, per-worker isolation, API consumes by
  value).
- Cross-reference the consuming API's `&mut` signature if the clone exists
  to satisfy a `&mut self` boundary.

**Examples from the donor project:**
- an index clone for change-batch application (copy-on-write).
- `search_filters.clone()` per parallel worker (per-worker isolation).
- `offsets.clone()` for a CSR-build scratch buffer (single-writer
  scratch).
- `extent_map.clone()` per pipelined reader (one-time per-reader
  setup).

---

### 3.3  Category γ - Error / log context

**Pattern:**

```rust
fn load_input(path: &Path) -> Result<...> {
    // ...
    Err(LoadError::FileOpen {
        path: path.to_path_buf(),       // γ: own the path past the error site
        source: io_err,
    })
}
```

**Verdict:** KEEP.

Error paths are cold by definition - they only fire when something has
already gone wrong.  The cost of allocating a `PathBuf` / `String` for
context is dominated by the cost of the failure itself (system call, lock
release, retry logic).

**Workspace convention:**
- The clone / allocation must be inside an error-construction arm, a `log!`
  macro, or a `tracing!` event.
- Reason text in the surrounding code can be brief - the *category* is
  self-evident from the error/log context.

**Examples from the donor project:**
- `path.clone()` into a source-tagged error variant.
- `file_path.clone()` to own the path past the error site.
- per-request JSON-RPC response packaging (`val.clone()` for
  `serde_json::from_value` consumption).

---

### 3.4  Category δ - Hot-path anti-pattern

**Pattern (anti-pattern - DO NOT WRITE):**

```rust
for source in &sources {
    filters.resolve_ids_for_source(source);
    // ...
    // Defensive clone "in case we re-borrow `filters` later"
    for &id in &filters.resolved_ids.clone() {  // ⚠ δ
        // ... body never actually touches filters
    }
}
```

**Verdict:** FIX.

If the inner loop body does not actually re-borrow the parent state, the
clone is dead weight - a per-iteration allocation that the borrow checker
would accept without it.  These are the only category that **must** be
refactored, not suppressed.

**The fix is structural, not lint-driven.**  Common shapes:
- **Borrow narrower:** drop the clone; the immutable borrow scope ends when
  the inner loop returns to the outer.
- **Take by value:** if the caller owns the data, change the API to consume
  by value rather than clone-then-consume.
- **Static intern:** replace a per-row `format!` over a small closed set
  of values with a `[&'static str; N]` lookup table.
- **`Cow<'_, str>`:** for APIs that take `&str` but sometimes need an owned
  variant (e.g. case-folding), return `Cow<'_, str>` so the caller pays
  only when needed.

**Workspace convention:**
- δ fixes land as **standalone commits** with a one-paragraph rationale
  explaining the new ownership invariant.
- Reason text at the refactored site must document the new (correct)
  borrow invariant so future audits don't re-introduce the clone.

**Examples (all fixed in the donor project's allocation audit):**
- defensive `Vec<u16>::clone()` in two top-N query modules dropped
  (immutable borrow narrows).
- a per-row `format!` in a path-building hot loop replaced with in-place
  `String::push_str`.
- a per-row `format!` over a 26-value closed set replaced with a
  `[&str; 26]` lookup.
- a duplicated `to_owned()` pattern replaced with a `Cow<'_, str>`
  helper (the common path became zero-alloc).

---

### 3.5  Category ε - Test helper

**Pattern:**

```rust
#[cfg(test)]
mod tests {
    fn fixture_row(name: &str, size: u64) -> Row {
        Row::new(0, name.to_owned(), size)  // ε
    }
}
```

**Verdict:** KEEP (out of scope).

Test code is exempt from the allocation discipline.  Test fixtures and
helpers may clone freely so the test author can concentrate on the
*behavior* under test.

**Workspace convention:**
- `clippy.toml` carries `allow-*-in-tests = true` (covers `unwrap_used`,
  `expect_used`, `panic`, plus implicit Clippy test-context exemptions).
- ε sites are **not** counted in the per-crate audit numbers.
- New `#[cfg(test)]` code requires no `.clone()` justification.

---

## 4  The per-site annotation contract

Every prod `.clone()` / `format!()` / `to_owned()` site must satisfy one of:

1. **Self-evident category α (`Arc::clone(&x)` form):** no comment required -
   the explicit `Arc::clone(&x)` syntax is its own annotation.
2. **Category β / γ:** a 1–3 line `//` comment above (or trailing) the call
   site explaining *why* the alternative (`&T`, in-place mutation, etc.)
   doesn't work for this site.  Reason quality is checked at code review,
   not by lint.
3. **Category δ refactor:** comment block at the refactored site documents
   the new (correct) borrow / ownership invariant and cross-references the
   commit / PR that landed the fix.

The bar for reason quality is the same as the panic policy's
`#[expect(reason = "...")]` annotations: a future contributor (or auditor)
reading the comment should be able to reconstruct why the clone exists
without paging in the full surrounding module.

---

## 5  Audit cadence

The donor project maintained a standalone shell helper
(`clone_alloc_audit.sh`, `Bash 5.x` + `rg`) that produced the workspace
allocation inventory:

- `.clone()` calls per crate, split by `prod` vs `test`
- `format!` invocations per crate, split by `prod` vs `test`
- `to_string` / `to_owned` invocations per crate, split by `prod` vs `test`
- The top-10 per-file `.clone()` / `format!` hotspots in production code

This template does not ship the script; an equivalent quick sweep is
`rg -c '\.clone\(\)' crates/ --glob '!*test*'` per pattern.  Run a sweep
before opening any PR that touches a hot-path module; the absolute
counts should not regress.

---

## 6  Workspace cross-references

Every site that touches the allocation policy must cross-reference the
others to keep the contract auditable:

- `Cargo.toml` `[workspace.lints.clippy]` carries doc comments on each
  clone-family lint pointing at this file.
- `clippy.toml` carries a doc comment pointing at this file and at
  `panic_policy.md`.
- `CONTRIBUTING.md §Allocation policy` summarises the rule and links here.
- `panic_policy.md §1` covers the test/prod split that this doc inherits.
- `lint-posture.md §4` covers the broader test-vs-prod split.

---

## 7  Decisions log

This section is append-only.  Add new rows above the divider; do not edit
existing rows (they document the *evolution* of the policy).  The rows
below are inherited donor-project history, kept as a worked example of
the log format - reset the table when you adopt this template.

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-05-12 | `clone_on_ref_ptr = "deny"` adopted; explicit `Arc::clone(&x)` form mandatory | Pre-Phase-6 baseline; makes Arc refcount bumps visible at every call site |
| 2026-05-12 | `redundant_clone = "deny"` / `inefficient_to_string = "deny"` / `cloned_instead_of_copied = "deny"` / `unnecessary_to_owned = "deny"` adopted | Mechanical guard against the most common cat-δ shapes |
| 2026-05-19 | `clone_alloc_audit.sh` shipped as a standalone helper (Phase 6a, PR #281) | Reproducible workspace inventory; baselines the per-crate counts before any code change |
| 2026-05-19 | Two cat-δ sites in `path_only_top_n` / `path_sorted_top_n` refactored (Phase 6c, PR #282) | Defensive `Vec<u16>::clone()` dropped - inner loop never re-borrows |
| 2026-05-19 | Two cat-δ sites in `path_resolver::fast` / `search::dataframe_convert` refactored (Phase 6d, PR #283) | Per-row `format!` replaced with in-place `push_str` and `[&str; 26]` static lookup |
| 2026-05-19 | `fold_needle` helper returning `Cow<'_, str>` extracted (Phase 6e, PR #284) | Case-sensitive query path now zero-alloc; case-insensitive path unchanged |
| 2026-05-19 | This document created (Phase 6f) | Codifies the five-category decision tree and per-site annotation contract for future contributors |

---

## 8  See also

- [`panic_policy.md`](panic_policy.md) - panic / unwrap / expect rules
- [`lint-posture.md`](lint-posture.md) - full lint configuration
  (rustfmt, rustc, clippy, rustdoc, cargo-deny)
- [`../../SECURITY.md`](../../SECURITY.md) - cargo-deny + cargo-vet
  supply-chain posture
- Root `Cargo.toml` `[workspace.lints]` - source of truth for the
  deny-list
- Root `clippy.toml` - clippy configuration source of truth
