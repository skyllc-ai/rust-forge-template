# ACMEX Build Script, Macro, Codegen, and Environment Policy

> **Companion documents:**
> [`panic_policy.md`](panic_policy.md),
> [`allocation_policy.md`](allocation_policy.md),
> [`trait_policy.md`](trait_policy.md),
> [`dependency_policy.md`](dependency_policy.md),
> [`lint-posture.md`](lint-posture.md).

> **Provenance note.** This policy was extracted from a donor project
> (a Windows NTFS file-search tool).  The rules and contracts apply to
> this workspace as-is; the registries in §5-§6 have been reset to the
> template's actual surface, and donor-specific worked examples are
> marked as such.

ACMEX keeps **compile-time magic justified and traceable** so the
workspace builds the same way on every supported host, contributors
can reason about what each `build.rs` and macro does without running
the build, and the environment-variable surface stays inventoried.
This document is the project's **build / macro / codegen / env
contract**: it codifies *which* `build.rs` files exist, *what each
generates*, *which* `macro_rules!` declarations the workspace allows,
*which* codegen binaries run and how their drift is detected, and
*every* environment variable the workspace reads.

---

## 1  The rule

Stated as a one-liner contributors can quote:

> **Every `build.rs` falls into one of the three justification
> classes below.  Every `macro_rules!` falls into one of the three
> justification classes below; control-flow hiding is forbidden.
> Every codegen binary has a drift detector or a documented "no
> idempotency contract" rationale.  Every environment variable the
> workspace reads is in the §5 registry below with name, scope, type,
> default, where read, and semver class.**

The categories:

### 1.1 `build.rs` justification classes

| Class | Pattern | Verdict |
|---|---|---:|
| **B1 — Native library detection** | `pkg-config` / `vcpkg` / probing for an externally-installed C/C++ library | **KEEP** if necessary; document the platform expectations inline |
| **B2 — Code generation tied to build inputs** | Reading a non-Rust input file (icon, manifest, schema) and producing a build artifact (PE resource section, generated `.rs`, etc.) | **KEEP** if no Rust-source equivalent exists |
| **B3 — Compile-time probing that cannot move elsewhere** | Emitting `cargo:rustc-link-arg-*`, `cargo:rustc-cfg=*`, or similar directives whose only sink is `build.rs` | **KEEP** if the directive has no `#[link]` / `#[cfg_attr]` equivalent |
| **B-X — Convenience** | "It seemed convenient once" | **FORBIDDEN** — refactor to plain Rust, a checked-in generated file, or a one-time tool |

### 1.2 `macro_rules!` justification classes

| Class | Pattern | Verdict |
|---|---|---:|
| **M1 — Syntax shaping** | Variadic args, embedded `?`-propagation, implicit closure-like captures — a shape a function cannot express cleanly | **KEEP** |
| **M2 — Trait/impl repetition** | Generates repeated `impl Trait for Type` blocks where bodies differ only mechanically | **KEEP** |
| **M3 — Pattern capture** | Captures a syntactic pattern that has no first-class expression in Rust (e.g. `const` declarations from a list) | **KEEP** |
| **M-X — Control-flow hiding** | A macro that could be a plain function but is a macro for stylistic reasons | **FORBIDDEN** |

### 1.3 Codegen binary classes

| Class | Pattern | Verdict |
|---|---|---:|
| **C1 — Emitter / validator with drift detector** | Reads a source-of-truth, emits an artifact (or `--check`-validates one); paired with a `*-drift` gate in `scripts/ci/gates.toml` | **KEEP** |
| **C2 — Orchestrator without idempotency contract** | Drives a process (release, deploy) whose output is state, not a static artifact | **KEEP** if integration tests cover the logic; document the C2 rationale |
| **C-X — Bespoke unaudited generator** | Codegen binary outside the gates manifest, with no drift detector and no integration tests | **FORBIDDEN** |

Test code is exempt from this policy — see
[`clippy.toml`](../../clippy.toml) `allow-*-in-tests = true` and the
test-substitution boundary documented in
[`panic_policy.md` §1](panic_policy.md).

---

## 2  The lint posture

This policy introduces **no new clippy lints**.  Build, macro, codegen,
and env-var hygiene is enforced through four complementary tools wired
into pre-push and CI:

| Tool | What it catches | Where |
|---|---|---|
| `scripts/ci/acmex-manifest-audit` (`manifest-drift` gate) | Workspace-inheritance invariants in `Cargo.toml` | Pre-push + `pr-fast.yml::manifest-drift` |
| `scripts/ci/acmex-gen-hooks` (`hooks-drift` + `fast-drift` gates) | `_lint_pre_push.sh` + `_lint_fast.sh` drift from `gates.toml` | Pre-push + `pr-fast.yml::hooks-drift` + `pr-fast.yml::fast-drift` |
| `scripts/ci/acmex-gen-workflow` (`workflow-drift` gate) | `pr-fast.yml` drift from `gates.toml` | Pre-push + `pr-fast.yml::workflow-drift` |
| `cargo build --workspace --timings` | Compile-time regression from a new `build.rs` or macro-heavy site | Pre-release + on-demand |

The contract is positive (a registry diff flags what's missing) rather
than negative (no new clippy lints to suppress) because the surface area
is too small to justify a dedicated lint — the template workspace has 5
`build.rs` files (all one shape), 0 proc-macros, 0 `macro_rules!` sites,
4 codegen binaries, and a single-digit env-var surface.  A registry diff
catches drift more cheaply than a custom lint.

---

## 3  Per-section contracts (the four sub-contracts)

### 3.1  `build.rs` contract

Every `build.rs` added to the workspace must:

- **Document its justification class** (B1 / B2 / B3) inline at the top of the file in the crate-level rustdoc.
- **Declare every filesystem read** via `cargo:rerun-if-changed=<path>`.
- **Declare every env-var read at build time** via `cargo:rerun-if-env-changed=<NAME>` *unless* the env var is in the `CARGO_*` family (auto-tracked by Cargo).
- **Gate platform-specific work** on `target_os` / `target_env` / `target_family` / `target_arch` cfg values read from `CARGO_CFG_*` env vars.
- **Use `#[allow(clippy::expect_used, reason = "build-host panic")]`** for build-host failure modes; `panic_policy.md` §1 exempts build scripts from the runtime panic policy.

### 3.2  Proc-macro crate contract

Introducing a proc-macro crate (a crate with `proc-macro = true` in its
`[lib]` table) requires:

- **A unanimous-review decision** captured in §10 below with the trade-offs.
- **A compile-time impact analysis** — proc-macros add compile cost workspace-wide because every consumer must link the proc-macro at compile time; the analysis must show the cost is justified.
- **A boundary contract** — which crates may depend on the proc-macro crate, and the public API surface (`#[proc_macro]` / `#[proc_macro_derive]` / `#[proc_macro_attribute]` exports).
- **A test suite** — proc-macros are unit-testable via `trybuild`; the new crate must ship with a failing-and-passing test matrix.

The current workspace has **0 proc-macro crates** as a deliberate
posture (see §6).  This is not a hard ban — it is a "high bar to
clear" posture.

### 3.3  `macro_rules!` contract

Every `macro_rules!` declaration must:

- **Justify itself** in its rustdoc comment (M1 / M2 / M3).
- **Be `pub(crate)`-scoped or narrower** unless the macro is part of a published library API (no such macros exist today).
- **Live in a single crate** (no cross-crate macro graphs without an explicit `#[macro_export]` justification).
- **Have a non-macro test surface** when feasible — the *output* of the macro should be covered by ordinary unit tests, not the macro itself.

### 3.4  Codegen binary contract

Every workspace-internal codegen binary (under `scripts/ci/` or
`scripts/ci-pipeline/`) must:

- **Have a `--check` mode** (class C1) OR **a documented "process, not file" rationale** (class C2).
- **Be wired into `scripts/ci/gates.toml`** as a `*-drift` gate when class C1.
- **Have an integration test suite** under `<binary>/tests/`.
- **Document its source-of-truth → artifact relationship** in its crate-level rustdoc.

### 3.5  Environment variable contract

Every environment variable the workspace reads (via `env::var(…)` /
`env::var_os(…)` / `env!(…)` / `option_env!(…)`, including reads via a
`const NAME: &str = "VAR";` indirection) must be in the §5 registry with:

- **Name** — the exact env var key.
- **Type** — `bool` (parsed permissively: `"1"` / `"true"` / `"yes"` truthy; everything else falsy unless documented otherwise; `env::var_os(…).is_some()` shape treats *any* set value as truthy and is noted inline) / `int` / `path` / `token` / `string`.
- **Default** — value used when the variable is unset.
- **Set by** — who is expected to write it: `Cargo` (automatic), `OS / shell` (system), `operator / user shell` (manual export), `CI workflow` (set by a `scripts/ci/` runner), `test harness`, ``just ship` cross-check`, etc.  This is the *expected* writer, not the only possible writer.
- **Where read** — the canonical use-site (file:line).
- **Semver class** — `STANDARD` (system-provided, never breaks: `HOME`, `PATH`), `CARGO` (Cargo-provided, see Cargo's stability promises), or `INTERNAL` (ACMEX-defined, can be added / removed / renamed in any minor version with a CHANGELOG entry).

---

## 4  Hygiene rules

### 4.1 No new `build.rs` without justification

Adding a new `build.rs` to a member crate requires:

1. A `build_codegen_policy.md` §6 registry entry naming the justification class (B1 / B2 / B3).
2. The crate-level rustdoc on the new `build.rs` must document the class inline.
3. The new file must declare its inputs via `cargo:rerun-if-changed=` / `cargo:rerun-if-env-changed=` directives and document any target gate.

### 4.2 No new proc-macro crate without unanimous review

Adding `proc-macro = true` to any crate requires a §10 decisions-log
entry recording the unanimous review.  The default disposition is
"don't add one" — proc-macros impose a workspace-wide compile-time
cost.

### 4.3 No new `macro_rules!` that hides ordinary control flow

If a macro could be written as a plain function (taking ordinary types
and returning ordinary values, with `?`-propagation at the call site
instead of inside the macro body), it should be a plain function.
Class M-X violations are caught at PR review.

### 4.4 No new codegen binary without a drift detector

Adding a new emitter under `scripts/ci/` requires:

1. A corresponding `*-drift` gate in `scripts/ci/gates.toml`.
2. The gate wired into both `_lint_pre_push.sh` (via `acmex-gen-hooks`) and `.github/workflows/pr-fast.yml`.
3. An integration test suite under `scripts/ci/<binary>/tests/`.

An orchestrator (class C2) is exempt from the drift-detector requirement
but must document its C2 rationale in its crate-level rustdoc.

### 4.5 No new env var without a §5 registry entry

Adding `env::var("ACMEX_FOO")` (or `env!("FOO")` / `option_env!("FOO")`)
requires a corresponding row in §5 in the same PR.

### 4.6 Env-var name conventions

- `ACMEX_*` — internal knobs; INTERNAL semver class.
- `ACMEX_<CRATE>_*` — per-crate consumer knobs; INTERNAL.
- `ACMEX_*_TEST_*` — test-only env vars; INTERNAL (no semver class because not user-facing).
- `RUST_LOG` / `RUST_LOG_FILE` — `tracing-subscriber` standard; STANDARD class.
- `CARGO_*` — Cargo-provided; CARGO class.

---

## 5  Environment variable registry

**As of:** template extraction.  This registry reflects the template's
actual surface.  (For scale: the donor project's version of this table
grew to 42 distinct names across 7 scope categories — build-time,
standard runtime, logging, runtime knobs, client knobs, build/release
knobs, test-only.  Expect yours to grow the same way; keep every row
current.)

### 5.1 Build-time (read inside `acmex_version::emit_build_env`, which every workspace `build.rs` calls)

| Name | Type | Default | Set by | Where read | Notes |
|---|---|---|---|---|---|
| `RUSTC` | `path` | `rustc` | Cargo | `crates/acmex-version/src/lib.rs` | Compiler binary used to capture the rustc version string.  CARGO class. |
| `TARGET` | `string` | (set by Cargo) | Cargo | `crates/acmex-version/src/lib.rs` | Target triple stamped into the build fingerprint.  CARGO class. |
| `PROFILE` | `string` | (set by Cargo) | Cargo | `crates/acmex-version/src/lib.rs` | Build profile (`debug` / `release`) stamped into the fingerprint.  CARGO class. |

### 5.2 Compile-time (stamped by `build.rs` via `cargo:rustc-env`, read with `option_env!` / `env!`)

| Name | Type | Default | Set by | Where read | Notes |
|---|---|---|---|---|---|
| `ACMEX_GIT_SHA` | `string` | `unknown` | `build.rs` | `crates/acmex-version/src/lib.rs` (macros) | Git sha in `--version -v` output.  INTERNAL class. |
| `ACMEX_COMMIT_DATE` | `string` | `unknown` | `build.rs` | `crates/acmex-version/src/lib.rs` | Commit date in the build fingerprint.  INTERNAL class. |
| `ACMEX_RUSTC` | `string` | `unknown` | `build.rs` | `crates/acmex-version/src/lib.rs` | rustc version in the build fingerprint.  INTERNAL class. |
| `ACMEX_TARGET` | `string` | `unknown` | `build.rs` | `crates/acmex-version/src/lib.rs` | Target triple in the build fingerprint.  INTERNAL class. |
| `ACMEX_PROFILE` | `string` | `unknown` | `build.rs` | `crates/acmex-version/src/lib.rs` | Build profile in the build fingerprint.  INTERNAL class. |
| `CARGO_PKG_VERSION` | `string` | (set by Cargo) | Cargo | `crates/acmex-version/src/lib.rs` + binaries | Crate version string in `--version` output.  CARGO class. |

### 5.3 CI tooling (read by the `scripts/` crates)

| Name | Type | Default | Set by | Where read | Notes |
|---|---|---|---|---|---|
| `CARGO_TARGET_DIR` | `path` | `target/` | Cargo / user shell | `scripts/ci-pipeline/src/context.rs` | Custom target-directory override.  CARGO class. |
| `HOME` | `path` | (Unix: user home) | Unix shell login | `scripts/ci-pipeline/src/context.rs` | Used to locate per-user caches.  STANDARD class. |

(`RUSTC_WRAPPER` is *written* — not read — by `scripts/ci-pipeline` to
toggle sccache for child builds; writes are out of scope for this
registry but noted here to keep the name discoverable.)

**Total: 11 distinct env-var names** across 3 scope categories.

---

## 6  Per-crate registry

**As of:** template extraction.

### 6.1 `build.rs` registry

| Crate | `build.rs`? | Class | Generates | Inputs |
|---|:---:|---|---|---|
| `acmex-cli` | ✅ | **B3** | `cargo:rustc-env=ACMEX_*` build-fingerprint stamps via `acmex_version::emit_build_env()` | git HEAD, `RUSTC` / `TARGET` / `PROFILE` env |
| `scripts/ci-pipeline`, `scripts/ci/acmex-gen-hooks`, `scripts/ci/acmex-gen-workflow`, `scripts/ci/acmex-manifest-audit` | ✅ | **B3** | Same shape — each calls `acmex_version::emit_build_env()` | Same |
| `acmex-core`, `acmex-version` | — | (none) | — | — |

(Donor example of a **B2** entry: the donor's CLI `build.rs` embedded a
PE `.rsrc` section — icon + `app.manifest` — via `winresource` and
emitted `/DELAYLOAD` linker args.  Projects that need Windows resource
embedding grow their `build.rs` the same way.)

### 6.2 Proc-macro registry

**0 proc-macro crates** workspace-wide.

The deliberate non-introduction is the workspace posture.  Adding one
requires the §3.2 contract.

### 6.3 `macro_rules!` registry

**0 `macro_rules!` declarations** in the skeleton crates — this
registry starts empty.

(Donor examples of justified entries: five `read_uN!` binary-read
helpers classed **M1** — embedded `?`-propagation + implicit
`(data, &mut pos)` captures that a function cannot express without
boilerplate at ~30 call sites — and one `*_consts!` macro classed
**M2 + M3**, generating 26 `pub const` declarations from a list,
because `const` items cannot be generated by functions.)

### 6.4 Codegen binary registry

| Binary | Class | Source of truth | Generated artifact | Drift gate |
|---|---|---|---|---|
| `scripts/ci/acmex-gen-hooks` | **C1** | `scripts/ci/gates.toml` | `scripts/hooks/_lint_pre_push.sh` + `scripts/hooks/_lint_fast.sh` | `hooks-drift` + `fast-drift` |
| `scripts/ci/acmex-gen-workflow` | **C1** | `scripts/ci/gates.toml` | `.github/workflows/pr-fast.yml` (validated, not emitted) | `workflow-drift` |
| `scripts/ci/acmex-manifest-audit` | **C1** | the manifest invariants encoded in its `audit.rs` | every member `Cargo.toml` (validated, not emitted) | `manifest-drift` |
| `scripts/ci-pipeline` | **C2** | N/A | N/A (process: validation + release orchestration) | N/A — see §3.4 |

---

## 7  Anti-patterns

The audit explicitly checks for and rejects:

| Anti-pattern | Why it's rejected | Correct alternative |
|---|---|---|
| `build.rs` that re-implements `cfg!()` logic in shell-style env probing | `build.rs` should *emit* cfg directives, not re-derive them; Cargo already exposes `target_*` via `CARGO_CFG_*` | Read `CARGO_CFG_TARGET_OS` etc. and gate the effectful block accordingly |
| `build.rs` that calls external commands (`git`, `make`) without `cargo:rerun-if-changed=` declarations | Causes silent stale-cache builds; CI passes, local fails | Either declare the command's input files as `rerun-if-changed=` or move the work to a one-time tool |
| Macro that takes `&self` / `&mut self` and could be an inherent method | Hides ordinary method-call shape behind macro syntax | Make it an inherent method |
| Macro that wraps a `match` or `if let` with a single arm | Hides ordinary control flow | Inline the `match` / `if let` |
| Proc-macro crate that depends on more than 3 transitive crates | Compile-time cost on every consumer | Re-implement using `syn::parse_str` or move logic to a build-script-emitted file |
| Codegen binary that emits a `.rs` file without a drift detector | Generated code can drift from source-of-truth silently | Add a `*-drift` gate to `scripts/ci/gates.toml` |
| Env var read without a §5 registry entry | Surface drift: future contributors don't know the var exists | Add a §5 row before merging the read |
| Env var with name `FOO` (single short uppercase word) | Collides with system / shell vars; `X`-style false positives in audits | Prefix `ACMEX_` or use a standardized name (`HOME`, `PATH`, `XDG_*`) |

---

## 8  Audit cadence

- **On every workspace-wide refactor sweep**, re-audit (targeted `rg` passes over `build.rs` files, `macro_rules!`, `env::var` / `env!` / `option_env!` reads) and refresh §6.1 (`build.rs`), §6.3 (`macro_rules!`), §6.4 (codegen), and §5 (env-var registry).  Update §10 with a decisions-log row.
- **On every new env-var introduction**, add a §5 row in the same PR that adds the `env::var(…)` call.
- **On every new `build.rs`**, add a §6.1 row in the same PR + add the file-level rustdoc justification per §3.1.
- **On every new `macro_rules!`**, add a §6.3 row + the macro's own rustdoc justification per §3.3.
- **On every new codegen binary**, add a §6.4 row + the corresponding `*-drift` gate in `scripts/ci/gates.toml`.
- **Annual cadence**, re-run the full sweep + refresh the env-var registry; catches drift from cleanups that removed an env var without removing its registry row.

---

## 9  Cross-references

- **Companion policies:** `panic_policy.md` (exempts `build.rs` from the runtime panic policy), `allocation_policy.md`, `trait_policy.md`, `dependency_policy.md` (same contract shape for features).
- **Gates manifest:** `scripts/ci/gates.toml` — the substrate that `acmex-gen-hooks` + `acmex-gen-workflow` consume; see §6.4.
- **Manifest invariants:** `scripts/ci/acmex-manifest-audit` — the invariants it encodes live in its source + tests.
- **Workspace lints:** `Cargo.toml [workspace.lints.clippy]` + `clippy.toml` — this policy adds **no new clippy lints**.

---

## 10  Decisions log

Append-only.  Each entry: date, sub-phase, decision, PR.  The rows
below are inherited donor-project history, kept as a worked example of
the log format — reset the table when you adopt this template.

| Date | Sub-phase | Decision | PR |
|---|---|---|---|
| 2026-05-19 | 9a | Land a build/macro/codegen/env baseline audit tool (donor).  Emits Markdown to stdout; reruns in ~1 s. | #299 |
| 2026-05-19 | 9b | `acmex-cli/build.rs` audited.  Verdict: B2 + B3 (PE resource embedding + `/DELAYLOAD` link args).  No drift.  No refactor.  See `phase_9_build_audit_findings.md`. | #300 |
| 2026-05-19 | 9c | Record deliberate "0 proc-macro crates" workspace posture.  Adding one requires the §3.2 contract. | #300 |
| 2026-05-19 | 9d | All 6 `macro_rules!` sites audited.  Verdict: 5 × M1 (binary read helpers — embedded `?`-propagation + implicit captures), 1 × M2+M3 (`drive_letter_consts!` — 26-letter const declaration repetition).  No drift.  Refactor candidate (read helpers → `Cursor` struct) deferred — see `phase_9_macro_audit_findings.md` §5.1. | #300 |
| 2026-05-19 | 9e | All 4 codegen binaries audited.  Verdict: 3 × C1 (`acmex-gen-hooks`, `acmex-gen-workflow`, `acmex-manifest-audit` — all `--check`-mode validators wired into `*-drift` gates) + 1 × C2 (`ci-pipeline` — release orchestrator, no idempotency contract).  No drift.  See `phase_9_codegen_inventory.md`. | #300 |
| 2026-05-19 | 9f | Env-var registry §5 populated: 36 distinct names across 7 scope categories (5 build-time, 11 standard-runtime, 5 logging, 9 ACMEX runtime knobs, 2 client knobs, 2 build/release knobs, 2 test-only). | #300 |
| 2026-05-19 | 9g | Policy doc + CONTRIBUTING §"Build, codegen, and env-var policy" cross-link landed.  Mirrors Phase 5e / 6f / 7g / 8c cadence. | #300 |
| 2026-05-19 | 9-gap | **Gap closure post-#300.**  Deep audit against playbook §1013-1078 + plan §0.2 identified 5 gaps: (A) §5 was missing the **Set by** column required by plan §0.2 item 5; (B) per-crate `# Environment` rustdoc sections deferred (plan §1 row 9f deliverable); (C) `crates/acmex-cli/build.rs` rustdoc was missing the env-var listing required by plan §2 criterion 3; (D) `count_includes` over-counted doc-comments by 1; (E) audit script missed `env::var_os(…)` + const-name indirection detection, causing **6 env vars** to be absent from §5 (`ACMEX_CACHE_PROFILE`, `ACMEX_HOT_TO_WARM_IDLE_SECS`, `ACMEX_REBUILD_CHILDREN_ALWAYS`, `ACMEX_SEARCH_MAX_CONCURRENCY`, `ACMEX_SKIP_ORPHANS`, `ACMEX_USN_REFRESH_INTERVAL_SECS`).  Corrected workspace baseline 36 → 42 env vars + 2 → 1 include sites.  Also corrected stale defaults for `ACMEX_PARKED_TO_COLD_IDLE_SECS` (300 → 86 400) and `ACMEX_WARM_TO_PARKED_IDLE_SECS` (60 → 300). | this PR |
