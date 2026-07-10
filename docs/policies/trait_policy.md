# ACMEX Trait, Generic, and Dispatch Policy

> **Companion documents:**
> [`panic_policy.md`](panic_policy.md),
> [`allocation_policy.md`](allocation_policy.md),
> [`lint-posture.md`](lint-posture.md).

> **Provenance note.** This policy was extracted from a donor project
> (a Windows NTFS file-search tool).  The rules and taxonomies apply
> to this workspace as-is.  The worked examples, per-trait registry,
> audit findings, and decisions log below are **illustrative donor
> examples** - the template skeleton itself currently declares no
> traits - kept to show what a mature project's version of this
> document looks like.

## 1  The rule

A trait must satisfy at least one of:

- **[J1]** multiple meaningful implementations,
- **[J2]** a test-substitution boundary (prod impl + test fake),
- **[J3]** a stable extension surface documented in rustdoc, or
- **[J4]** high-level / infrastructure decoupling at a clean architectural boundary.

Otherwise it's decoration - demote to a concrete type.

Generics stay **local** (callers see them only when they benefit).  Use **`dyn`** for plugin / runtime / OS-abstraction boundaries; use **static dispatch** for closed sets and hot-path closures.  Seal `pub trait`s only when external impls would break a documented invariant; prefer **structural sealing** (private fields on the return type) over an explicit `Sealed` supertrait when the trait's return type already carries the invariant.

## 2  The lint posture

The workspace enforces this policy through five clippy lints in `Cargo.toml [workspace.lints.clippy]`:

| Lint | Level | Catches | Phase |
|---|---|---|---|
| `clippy::type_complexity` | `deny` | Trait-bound / generic-bound chains over the default complexity threshold (250) | Phase 6 (carried over) |
| `clippy::too_many_arguments` | `deny` | `fn` signatures with more than the default 7 parameters | Phase 7f |
| `clippy::trait_duplication_in_bounds` | `deny` | Duplicate trait bounds on the same generic parameter (e.g. `T: Foo + Foo + Bar`) | Phase 7f |
| `clippy::wrong_self_convention` | `deny` | Inherent-method naming that violates the `as_*` / `into_*` / `to_*` / `from_*` conventions | Phase 7f |
| `clippy::multiple_bound_locations` | `warn` | Bounds split between `<T: …>` and `where T: …` for the same `T` | Phase 7f |

Per-site overrides (`#[expect(clippy::too_many_arguments, reason = "…")]`) are permitted only when the function genuinely needs more than 7 parameters and the rationale is documented inline.

Tests are relaxed via `clippy.toml`'s `allow-*-in-tests` settings (see [`lint-posture.md`](lint-posture.md)).

## 3  The four-criterion trait justification taxonomy

A `pub trait` or `pub(crate) trait` is justified iff at least one of J1–J4 holds.

### 3.1  [J1] - Multiple meaningful implementations

Two or more prod impls of the trait exist in the workspace **on `main`** (not hypothetical "someday we might add another impl").  Examples from the donor project:

- `JournalSource` (`acmex-daemon::cache::journal_loop`): `MacStubJournalSource` (always-empty on Mac/Linux) + `WindowsJournalSource` (`FSCTL_READ_USN_JOURNAL` on Windows).
- `RuntimeDir` (`acmex-security`): `UnixRuntimeDir` (`0o600` + `kill(pid, 0)`) + `WindowsRuntimeDir` (`FILE_SHARE_NONE` + `OpenProcess`).
- `FormatRow` (`acmex-format`): `acmex_core::search::backend::DisplayRow` (offset-into-path) + `acmex_client::protocol::response::SearchRow` (standalone `String`).

### 3.2  [J2] - Test-substitution boundary

A production impl exists, and at least one test fake under `#[cfg(test)]` or `tests/*.rs` exists.  The trait is the deliberate seam between prod side-effects and deterministic test fixtures.  Examples from the donor project:

- `BodyLoader` (`acmex-daemon::cache::body_loader`): `DiskBodyLoader` prod + fakes in `tests/body_loader_fakes.rs`.
- `FileReader` (`acmex-core::aggregate::verify`): `DaemonFileReader` prod (in `acmex-daemon`) + `MockReader` test fake.
- The full `acmex-daemon::cache::*` 9-trait cluster: `BackgroundIoPriority`, `BodyLoader`, `CacheCleaner`, `CursorStore`, `JournalSource`, `PatchSink`, `Prefetch`, `PressureSignal`, `WorkingSetTrim`.  Each holds an OS-side-effect that needs stubbable substitution in tests.

### 3.3  [J3] - Stable extension surface

The trait's rustdoc explicitly invites external impls and documents the extension contract.  Examples from the donor project:

- `FileReader`: *"External crates may implement FileReader to plug in alternate I/O strategies (e.g. async readers, network-backed readers) without changes to acmex-core."*
- `FormatRow`: *"consumers can plug their own row representation if they ever need to (e.g. a future Parquet-shaped row backend)."*

J3 is a stronger claim than J1: J1 says "multiple impls exist"; J3 says "we welcome more from outside our workspace".

### 3.4  [J4] - High-level / infrastructure decoupling

The trait crosses a clean architectural boundary - typically from a library-layer service down to an infrastructure-layer driver - and the consumer side is documented to be testable / swappable independently.  In the donor project's audit, J4 sites overlapped heavily with J2 (the OS-hook traits); pure J4 sites are rare.

### 3.5  Demotion criterion

A trait satisfying **none** of J1–J4 → demote to a concrete type and replace usages.  The donor project's single demotion (`DirCacheExt` → a free `dir_cache_with_capacity(n)` function) is the canonical example: single impl, no test fake, `pub(crate)`, no extension surface, no decoupling - pure method-sugar that required every caller to write `use … DirCacheExt as _;`.

## 4  The generic-function taxonomy

Five categories partition every prod-path `fn<T: …>` site:

| Category | Description | Verdict |
|---|---|---|
| **[G1-LOCAL]**     | Generic-ness contained within the function body; callers do not have to think about `T` (e.g. `<T: Iterator<Item = …>>` consumed once internally) | KEEP |
| **[G2-USEFUL]**    | Generic-ness extends to the call site but the caller benefits (e.g. `impl AsRef<Path>` lets callers pass `&str` / `String` / `&Path` / `PathBuf` without explicit conversion) | KEEP |
| **[G3-SPREAD]**    | Generic-ness has spread to multiple call sites without benefit; all call sites use the same concrete type | **FIX** - refactor to concrete |
| **[G4-CASCADING]** | Generic-ness forced upstream into structs / traits that did not need it | **FIX** - narrow scope or accept the bound at the source struct |
| **[G5-CLOSURE]**   | Generic `<F: Fn…>` parameter at a callsite that benefits from inlining (hot-path filter, comparator, progress callback) | KEEP |

The donor project's audit found **zero G3-SPREAD and zero G4-CASCADING sites** across all 127 prod generic-fn sites - its existing `impl AsRef<Path>` / `<W: Write>` / `<F: Fn…>` clusters were textbook G1/G2/G5 by construction.

## 5  The dispatch matrix

For each `dyn <Trait>` site:

| Category | Description | Verdict |
|---|---|---|
| **[D1-PLUGIN]**    | Pluggable backend / runtime registry (transport, encryption, OS abstraction) | KEEP |
| **[D2-HETERO]**    | Heterogeneous handler collection (`Box<dyn Read + Send>` for transport polymorphism; `&dyn Fn(…)` for runtime-selected callbacks; `Vec<Box<dyn Handler>>` for plugin registries) | KEEP |
| **[D3-NOOP]**      | `dyn Trait` used where the impl set is closed and single | **FIX** - refactor to concrete or `enum` |
| **[D4-VTBL-COST]** | `dyn Trait` on a hot path where monomorphization would inline a tight loop | **REVIEW** - measure first |

For each static-dispatch site that *could* be `dyn Trait`:

| Category | Description | Verdict |
|---|---|---|
| **[S1-MONOMORPH]**      | Performance-critical generic; monomorphization gives measurable inlining | KEEP |
| **[S2-OVER-MONOMORPH]** | Generic where monomorphization bloats binary size but inlining doesn't help | **REVIEW** - consider `dyn` |
| **[S3-CLOSED-SET]**     | Generic where only 2-3 impls exist and all are in this workspace | KEEP |

The donor project's audit found **40 true dispatch sites** (after dropping doc-comment matches from the raw 89): every site was D1-PLUGIN or D2-HETERO.  Zero D3-NOOP, zero D4-VTBL-COST, zero S2-OVER-MONOMORPH.

## 6  Seal/open decision tree

For each surviving `pub trait` (cross-crate-visible):

1. **Is the trait documented as an extension point?**  YES → **OPEN**.
2. **Is the trait's contract enforced structurally (private fields on the return type, no public constructor)?**  YES → **OPEN (effectively sealed)** - no explicit `Sealed` marker needed; document the structural reality in rustdoc.
3. **Could an external impl silently break a safety / correctness invariant?**  YES → **SEAL** with the explicit pattern below.
4. Otherwise → **OPEN** by default (the mantra is "controlled implementations", not "no implementations").

Explicit sealing pattern:

```rust
mod private { pub trait Sealed {} }
pub trait MyTrait: private::Sealed { /* ... */ }
impl private::Sealed for Impl1 {}
impl private::Sealed for Impl2 {}
```

The donor project's seal/open decisions for its 3 surviving `pub trait`s, as a worked example:

| Trait | Crate | Decision | Reason |
|---|---|---|---|
| `FileReader` | donor core crate | **OPEN** | Rustdoc invites external impls (J3). |
| `FormatRow` | donor format crate | **OPEN** | Rustdoc documents the Parquet-shaped extension intent (J3). |
| `RuntimeDir` | donor security crate | **OPEN (effectively sealed)** | The trait's `create_owner_only` method returns a `RuntimeFile`, whose fields (`file: File`, `path: PathBuf`) are private - external code cannot construct a `RuntimeFile`, so external impls of `RuntimeDir` are structurally impossible without a public constructor.  No explicit `Sealed` marker is added; the structural seal points readers at the actual cause - `error[E0451]: field file of struct RuntimeFile is private` - rather than a derived `Sealed` supertrait. |

## 7  Per-trait registry

The template skeleton declares **zero traits** - this registry starts
empty for a new project.  The donor project's registry is kept below
as a worked example of the format:

| Trait | Crate | Visibility | Prod impls | Test fakes | Verdict |
|---|---|---|---:|---:|---|
| `FileReader` | `acmex-core` | `pub` | 1 (`DaemonFileReader`) | 1 (`MockReader`) | KEEP-[J2]+[J3] |
| `BackgroundIoPriority` | `acmex-daemon` | `pub(crate)` | 1 (`PlatformBackgroundIoPriority`) | 1 | KEEP-[J2] |
| `BodyLoader` | `acmex-daemon` | `pub(crate)` | 1 (`DiskBodyLoader`) | ≥1 (`tests/body_loader_fakes.rs`) | KEEP-[J2] |
| `CacheCleaner` | `acmex-daemon` | `pub(crate)` | 1 (`PlatformCacheCleaner`) | 1 | KEEP-[J2] |
| `JournalSource` | `acmex-daemon` | `pub(crate)` | 2 (`MacStubJournalSource` + `WindowsJournalSource`) | 1 (`FakeJournalSource`) | KEEP-[J1]+[J2] |
| `PatchSink` | `acmex-daemon` | `pub(crate)` | 1 | 1 | KEEP-[J2] |
| `CursorStore` | `acmex-daemon` | `pub(crate)` | 1 (`NullCursorStore`) + 1 future | 1 (`FakeCursorStore`) | KEEP-[J2] |
| `Prefetch` | `acmex-daemon` | `pub(crate)` | 1 (`PlatformPrefetch`) | 1 | KEEP-[J2] |
| `PressureSignal` | `acmex-daemon` | `pub(crate)` | 1 (`PlatformPressureSignal`) | 1 | KEEP-[J2] |
| `WorkingSetTrim` | `acmex-daemon` | `pub(crate)` | 1 (`PlatformWorkingSetTrim`) | 1 | KEEP-[J2] |
| `FormatRow` | `acmex-format` | `pub` | 2 (`DisplayRow` + `SearchRow`, in distinct crates) | 0 | KEEP-[J1]+[J3] |
| `RuntimeDir` | `acmex-security` | `pub` | 2 (`UnixRuntimeDir` + `WindowsRuntimeDir`) | 1 (`TestRuntimeDir`) | KEEP-[J1]+[J2] |
| ~~`DirCacheExt`~~ | ~~donor core crate~~ | ~~`pub(crate)`~~ | - | - | **DEMOTED** → `dir_cache_with_capacity` free fn |

**Total active (donor):** 12 traits (3 `pub` cross-crate + 9 `pub(crate)` OS hooks).

## 8  Anti-patterns

The audit explicitly checks for and rejects:

- **Decoration trait** - single impl, no test fake, no rustdoc-claimed extensibility.  Example from the donor project: `DirCacheExt` (single method, single impl on a type alias, required `use … DirCacheExt as _;` at every call site for zero substitution benefit).  **Fix:** demote to a free function.
- **`dyn Trait` on a 2-impl closed set** - the closed set should be an `enum` with explicit variants, not a heap-allocated trait object.  **Fix:** convert to `enum`; if the variant payloads differ in size by > 8×, `Box` the largest arm to keep `clippy::large_enum_variant` happy.
- **Generic spread without measurable benefit** - generic parameter that monomorphizes to 1-2 concrete types in practice and adds compile-time without runtime win.  **Fix:** demote to concrete; the lost ergonomic is rarely worth the compile-time cost.
- **Bound list copy-paste** - `impl<T: Trait1 + Trait2 + Send + Sync + 'static>` repeated across 5 fn sigs.  **Fix:** extract a supertrait bound on the trait itself, or use a trait alias (`trait MyBound: Trait1 + Trait2 + Send + Sync + 'static {}` + blanket impl).
- **Explicit `Sealed` marker where structural sealing suffices** - adds two lines per impl + a private module + a supertrait bound, but does not change error-message clarity or behavior when the return type already carries the invariant.  **Fix:** rely on the existing private-field structural seal; document it in the trait's rustdoc.

## 9  Audit cadence

- **On every workspace-wide refactor sweep** - re-audit the trait inventory (`rg "^\s*(pub(\(crate\))? )?trait "`) and confirm the per-trait registry in §7 above is current.
- **On every new `pub trait` introduced** - justify J1/J2/J3/J4, decide seal-vs-open, document in §7.
- **On every new `pub(crate) trait` cluster** (e.g. a new subsystem with its own substitution surface) - re-audit and add the traits to §7.
- **Annually** as part of the workspace-health review.

## 10  Cross-references

- **Workspace lints:** `Cargo.toml [workspace.lints.clippy]` (5 trait/generic/dispatch lints documented in §2).
- **Test-code relaxations:** `clippy.toml` (`allow-*-in-tests` settings).
- **Companion policies:** [`panic_policy.md`](panic_policy.md), [`allocation_policy.md`](allocation_policy.md).
- **Lint-posture overview:** [`lint-posture.md`](lint-posture.md).

## 11  Decisions log

Append-only.  Each entry: date, sub-phase, decision, PR.  The rows
below are inherited donor-project history, kept as a worked example of
the log format - reset the table when you adopt this template.

| Date | Phase | Decision | PR |
|---|---|---|---|
| 2026-05-19 | 7a | Add a trait/generic/dispatch baseline audit tool (donor) | #288 |
| 2026-05-19 | 7b | Demote `DirCacheExt` to `dir_cache_with_capacity` free fn (only J0 trait found) | #289 |
| 2026-05-19 | 7c | Audit 127 generic-fn sites - all G1/G2/G5; zero refactor PRs | findings-only |
| 2026-05-19 | 7d | Audit 40 true dispatch sites - all D1/D2; zero refactor PRs | findings-only |
| 2026-05-19 | 7e | Keep all 3 surviving `pub trait`s OPEN - `FileReader` (J3), `FormatRow` (J3), `RuntimeDir` (structurally sealed by private fields of `RuntimeFile`) | findings-only |
| 2026-05-19 | 7f | Add 4 clippy lints: `too_many_arguments`, `trait_duplication_in_bounds`, `wrong_self_convention` (deny) + `multiple_bound_locations` (warn) | #291 |
| 2026-05-19 | 7g | Add this `trait_policy.md` + `CONTRIBUTING.md` cross-link | #290 |
