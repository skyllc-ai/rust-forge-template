# ACMEX Feature Flag and Dependency Policy

> **Companion documents:**
> [`panic_policy.md`](panic_policy.md),
> [`allocation_policy.md`](allocation_policy.md),
> [`trait_policy.md`](trait_policy.md),
> [`lint-posture.md`](lint-posture.md).

> **Provenance note.** This policy was extracted from a donor project
> (a Windows NTFS file-search tool).  The rules and tooling apply to
> this workspace as-is; the feature registry, duplicate inventory, and
> decisions log below are **illustrative donor examples** — the
> template skeleton currently declares no feature flags — kept to show
> what a mature project's version of this document looks like.

ACMEX keeps **feature behavior additive** and **dependency duplication
audited** so that downstream consumers can pick the smallest viable
subset without surprises and the supply chain stays inspectable on
every commit.  This document is the project's **feature + dependency
contract**: it codifies *which* feature flags exist, *what each
guarantees*, *how* a new feature is introduced, and *which*
cross-version dependency duplications the workspace accepts and why.

---

## 1  The rule

Stated as a one-liner contributors can quote:

> **Every feature is additive (enabling never removes an item).
> Every default feature has a written justification.  Every
> optional dep is reachable via `dep:<name>` and at least one
> `#[cfg(feature = "…")]` use-site.  Every cross-version
> dependency duplicate is either tracked in `deny.toml [bans].skip-tree`
> with a one-line reason, or accepted by the workspace-wide
> `multiple-versions = "warn"` posture and documented in §5.**

The categories:

| Category | Pattern | Verdict | Notes |
|---|---|---:|---|
| **F1 — additive, default-on** | Adds modules / items / deps; the default consumer keeps the historical surface | **KEEP** | Disabling is the consumer's deliberate "shrink the surface" choice (donor example: a client crate's `async` feature) |
| **F2 — additive, default-off** | Adds modules / items / deps; opt-in chooses to accept a cost (binary size, syscall surface, build time) | **KEEP** | Default-off only when the cost is observable to a *thin* consumer (donor example: an HTTP-probe feature that keeps a network DLL unlinked) |
| **F3 — orthogonal capability** | Two features compose without interaction (no `&&` cfg, no feature-on-feature ladder) | **KEEP** | Currently none — preserved as a category for future capability splits |
| **F4 — subtractive** | Disabling removes items the default consumer *had* | **FORBIDDEN** | Breaks Cargo's "feature unification" guarantee.  **Fix:** invert the polarity — make the *new* behavior the feature and the *legacy* behavior the default. |
| **F5 — feature-on-feature stack** | `foo = ["bar"]` where `bar` itself gates non-trivial deps | **REVIEW** | Document the cascade in each gated feature's rustdoc; verify no surprise dep activation |

Test code is exempt from the additivity rule — see
[`clippy.toml`](../../clippy.toml) `allow-*-in-tests = true` and the
test-substitution boundary documented in
[`panic_policy.md` §1](panic_policy.md).

---

## 2  The lint posture

This policy introduces **no new clippy lints**.  Feature and dependency
hygiene is enforced through six complementary tools wired into the
pre-push gate and CI:

| Tool | What it catches | Where |
|---|---|---|
| `cargo deny check` | License violations, advisories, source bans, multiple-version *deny*-level dups | `deny.toml` + `.github/workflows/pr-fast.yml::security` |
| `cargo machete` | Unused direct deps in any crate's `[dependencies]` | Pre-push gate + `pr-fast.yml::security` |
| `cargo vet` | Unaudited crate-versions in the dep graph | `supply-chain/{config,audits,imports.lock}.toml` + `pr-fast.yml::security` |
| `cargo tree --workspace -d` | Cross-version duplicate inventory | Run manually when re-baselining; no hard gate (workspace runs `multiple-versions = "warn"`) |
| `cargo doc --no-deps --all-features` | Broken intra-doc links inside `# Features` sections | Pre-push gate (`rustdoc`) + `pr-fast.yml::docs` |
| `cargo clippy --workspace --all-targets --no-default-features --no-deps -- -D warnings` | **Feature-additivity regressions** — `pub`/`pub(crate)` items reachable only when feature X is on but not themselves `#[cfg(feature = "X")]`-gated (manifests as `dead_code` warnings + unfulfilled `expect` warnings when feature X is off) | Pre-push gate (`lint-ci-no-default` — Phase 8e) + `pr-fast.yml::clippy-no-default` |

The sixth tool — `lint-ci-no-default` — is the feature-additivity
regression guard.  It mirrors the existing `lint-ci` gate
(`--all-features -D warnings`) but swaps in `--no-default-features`,
so the pair establishes the **additivity invariant**: every item
reachable only with feature X must compile cleanly both with feature X
off AND with all features on.  Without this gate, the `--all-features`
build masks the dead-code warning the `--no-default-features` build
emits, and additivity regresses silently.

`deny.toml` is configured at:

```toml
[bans]
multiple-versions = "warn"  # NOT "deny" — see §5 for rationale
wildcards         = "allow"
skip-tree         = [ … ]   # see §5
```

The `multiple-versions = "warn"` choice is deliberate (§5).  CI
remains green when a new transitive dup appears; a manual
`cargo tree --workspace -d` sweep is the human-driven re-baselining
step that decides per-group whether to add a `skip-tree` entry or
upstream a fix.

---

## 3  Feature flag contract

Every feature added to the workspace must document the four-line
contract in **both** the crate's root rustdoc (`# Features` section)
**and** as a block comment above the `[features]` block in
`Cargo.toml`:

```text
1. What it enables  — which module / item / subcommand / binary
2. What deps it adds — `dep:<name>` gating + transitive feature pulls
3. API shape impact — additive (default) | subtractive (forbidden)
4. Semver claim     — adding items behind it is non-breaking;
                      removing items behind it is breaking
```

The rustdoc section also documents **why the default is on or off**.
A default-on feature is breaking-on-disable; the rationale must
explain who the deliberate `default-features = false` consumer is.
A default-off feature must explain what cost the default consumer
avoids (binary size, syscall surface, build time, compile time).

Cross-link contract:

- The crate's `# Features` section links to this policy doc.
- The Cargo.toml `[features]` block comment links to the rustdoc
  section.
- The crate's `[package.metadata.docs.rs]` sets `all-features = true`
  so docs.rs renders every feature's gated items with their `#[doc(cfg)]`
  badge.

The donor project carried three reference implementations of this
contract (a client crate, an MCP crate, and its CLI); the template
skeleton has no feature flags yet, so the first feature you add
becomes the reference implementation.

---

## 4  Dependency hygiene rules

### 4.1  Direct deps

Every direct dep in a crate's `[dependencies]` table must be referenced
by at least one source file in that crate's `src/` tree.  `cargo
machete` enforces this on every push.  A crate that only uses a dep
transitively (e.g. for trait imports re-exported from another internal
crate) must *not* list it as a direct dep — that creates a cycle hazard
during dep upgrades.

### 4.2  Workspace pinning

Every direct dep is pinned at the workspace level in `Cargo.toml
[workspace.dependencies]` with an explicit `default-features` choice.
Per-crate manifests use `.workspace = true` so version drift is
impossible.  The two exceptions:

- **Path-with-version overrides** (e.g. a binary crate depending on an
  internal library with `{ path = "../acmex-core", version = "0.1",
  default-features = false }`) — workspace inheritance cannot override
  `default-features`, so the consumer crate must spell out the override
  explicitly.  Justified inline in the consumer Cargo.toml.
- **Internal crate path-with-version pins** for `cargo package`
  validation — required by the crates.io publish lane.

### 4.3  Optional deps

Every `optional = true` dep must be reachable via `dep:<name>` in at
least one feature activation, and the dep must have at least one
`#[cfg(feature = "…")]` use-site in the crate's `src/`.  An optional
dep without a `dep:` reference (or with one but no `cfg` use-site) is
dead weight and fails the audit.

### 4.4  Consumer-side `default-features = false` overrides

A crate that depends on an internal crate may drop default features
when:

1. The dropped feature is documented as **default-on for compatibility,
   off for binary-size discipline** (the canonical donor pattern was a
   client crate's `async` feature).
2. The consumer adds a comment in its own Cargo.toml explaining the
   override and what is lost.

### 4.5  Default features on internal crates

A new `default = ["…"]` on a workspace crate requires:

1. A rustdoc rationale in the `# Features` section of the crate.
2. Verification that every internal consumer either inherits the
   default cleanly or overrides with documented intent.
3. A line in §6's decisions log of this doc.

Removing an existing default is a breaking change and must be released
as such (a `feat!:` / major-bump commit).

---

## 5  Cross-version duplicate acceptance criteria

The workspace ships `multiple-versions = "warn"` (not `"deny"`)
deliberately.  The donor project's three reasons generalize:

1. **Heavy-dependency churn.**  A large ecosystem dependency (in the
   donor's case, polars) rotates which foundational crates land at
   which version on every bump (hashbrown, foldhash, getrandom, …).  A
   `deny`-level multiple-versions ban would force a skip-tree entry on
   every such bump — a maintenance hazard the warn-level posture
   sidesteps cleanly.
2. **Crate-family fragmentation.**  Related crates (e.g. the RustCrypto
   family) frequently straddle a coordinated major-version bump;
   aligning them is owned by a deliberate upgrade, not the dep-hygiene
   lane.
3. **Minor-version splits.**  Transitive deps frequently pin minor
   versions; absent an upstream coordination signal, accepting both
   versions is cheaper than forking.

The `deny.toml [bans].skip-tree` is the **opt-in** acceptance list —
entries documented inline with a one-line reason.  Crates surfaced by
`cargo tree -d` but absent from skip-tree are accepted by the
workspace-wide warn posture; the accepted inventory is documented here.

### 5.1  Inventory (donor-project example)

The donor project's close-of-audit inventory — 12 distinct
duplicate-version groups — is kept as a worked example of the format.
Reset this table against your own `cargo tree --workspace -d` output:

| Group | Versions | Skip-tree status | Source |
|---|---|---|---|
| `foldhash` | 0.1.5, 0.2.0 | **listed** (`foldhash@0.1`) | hashbrown 0.15 transitive |
| `getrandom` | 0.2.17, 0.3.4, 0.4.2 | **listed** (`getrandom@0.2`, `getrandom@0.3`) | ring + polars transitive |
| `hashbrown` | 0.15.5, 0.16.1, 0.17.1 | **listed** (`hashbrown@0.15`) | polars transitive |
| `itertools` | 0.13.0, 0.14.0 | **listed** (`itertools@0.13`) | polars transitive |
| `block-buffer` | 0.10.4, 0.12.0 | warn-only | RustCrypto `digest` 0.10 vs 0.11 |
| `cpufeatures` | 0.2.17, 0.3.0 | warn-only | RustCrypto `sha2` 0.10 vs 0.11 |
| `crypto-common` | 0.1.7, 0.2.1 | warn-only | RustCrypto `digest` 0.10 vs 0.11 |
| `digest` | 0.10.7, 0.11.2 | warn-only | RustCrypto `sha2` 0.10 vs 0.11 |
| `rand` | 0.9.4, 0.10.1 | warn-only | polars vs `rand_core` 0.6 vs 0.9/0.10 chain |
| `rand_chacha` | 0.9.0, 0.10.0 | warn-only | follows `rand` split |
| `rand_core` | 0.6.4, 0.9.5, 0.10.1 | warn-only | follows `rand` split |
| `sha2` | 0.10.9, 0.11.0 | warn-only | RustCrypto major-bump split |

Rerun `cargo tree --workspace -d` to refresh the inventory; any *new*
group not in the table above is a finding that needs a one-line
decision (add to skip-tree with rationale, or upstream a coordination
fix).

---

## 6  Per-crate feature registry

The template skeleton declares **zero feature flags** — this registry
starts empty for a new project.  The donor project's registry is kept
below as a worked example of the format:

| Crate | Feature | Default? | Activates | Optional deps gated | Use-sites |
|---|---|:---:|---|---|---:|
| `acmex-cli` | `mcp-http-probe` | no | `commands::system_status` probe path | — | 4 |
| `acmex-client` | `async` | yes | `connect::*` modules + async tests | `dep:tokio` | 6 |
| `acmex-mcp` | `streamable-http` | yes | `pub mod http` + `acmex-mcp-http` binary + `mcp_serve` helper | `dep:axum`, `dep:tower-service`, `rmcp/transport-streamable-http-server` | 5 |

**Total active (donor):** 3 feature flags across 3 of its 14 crates.

The donor's other 11 crates were intentionally feature-less — every
`pub` item unconditionally available.  Keeping most crates feature-less
keeps the cross-crate dep graph simple and the publishable-leaf surface
deterministic.

---

## 7  Anti-patterns

The audit explicitly checks for and rejects:

- **Subtractive feature** — disabling removes a `pub` item the default
  consumer had.  Breaks Cargo feature unification (any other workspace
  consumer that enables the feature wins; the "disabled" consumer
  silently re-acquires the item).  **Fix:** invert polarity — default
  is the *legacy* shape; the feature gates the *new* shape.
- **Default-on without justification** — a `default = ["foo"]` line
  without an explanatory rustdoc + Cargo.toml comment.  **Fix:** write
  the four-line contract (§3 above) or remove the default.
- **Optional dep without a `dep:` reference** — `optional = true` in
  `[dependencies]` but no feature carries `dep:<name>`.  Dead weight;
  the dep compiles into every consumer's lockfile but never participates
  in the build graph.  **Fix:** add the `dep:` gating, or remove the
  `optional` and the dep itself.
- **Feature-on-feature without rustdoc cascade** — `foo = ["bar"]`
  where `bar` itself pulls non-trivial deps, without a rustdoc note
  explaining what enabling `foo` transitively activates.  **Fix:**
  expand the `# Features` section to list the cascade.
- **Cross-version duplicate not in §5.1** — a `cargo tree -d` row not
  matching any group in the inventory above.  **Fix:** add a skip-tree
  entry with a one-line rationale, OR upstream a coordination fix, OR
  document the warn-only acceptance in §5.1 of this doc.
- **Direct dep without a use-site** — fails `cargo machete` at
  pre-push.  **Fix:** add the use-site, or remove the dep.

---

## 8  Audit cadence

- **On every workspace-wide refactor sweep** — re-run
  `cargo tree --workspace -d` + `cargo machete` and confirm the
  per-crate registry in §6 and the dup inventory in §5.1 are current.
- **On every new feature flag** — open a design review: justify F1/F2,
  write the four-line contract in rustdoc + Cargo.toml, add a row to
  §6, append to §10.
- **On every new `dep:<name>` activation** — verify `cargo machete`
  stays green and the use-site count is non-zero before merge.
- **On every heavy-dependency bump** — rerun the audit; expect
  duplicate-version churn in foundational crates; update §5.1 if a new
  group surfaces or an existing one goes away.
- **Annually** as part of the workspace-health review.

---

## 9  Cross-references

- **Workspace deps:** `Cargo.toml [workspace.dependencies]` (one
  versioned line per direct dep, used by every crate via
  `.workspace = true`).
- **Dep policy file:** [`../../deny.toml`](../../deny.toml).
- **Supply-chain audit trail:**
  [`../../supply-chain/config.toml`](../../supply-chain/config.toml),
  `audits.toml`, `imports.lock`.
- **Companion policies:** [`panic_policy.md`](panic_policy.md),
  [`allocation_policy.md`](allocation_policy.md),
  [`trait_policy.md`](trait_policy.md).
- **Lint-posture overview:** [`lint-posture.md`](lint-posture.md).

---

## 10  Decisions log

Append-only.  Each entry: date, sub-phase, decision, PR.  The rows
below are inherited donor-project history, kept as a worked example of
the log format — reset the table when you adopt this template.

| Date | Phase | Decision | PR |
|---|---|---|---|
| 2026-05-19 | 8a | Add a feature/dep audit baseline tool | #292 |
| 2026-05-19 | 8b | Document the 3 feature contracts in rustdoc + Cargo.toml | #293 |
| 2026-05-19 | 8c | Add this `dependency_policy.md` + `CONTRIBUTING.md` cross-link | #294 |
| 2026-05-19 | 8e | Add `lint-ci-no-default` regression guard + fix 6 feature-additivity gaps | #295 |
