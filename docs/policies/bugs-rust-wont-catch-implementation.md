<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2025-2026 Acmex Placeholder LLC.
-->

# Implementation Plan - Closing the "Bugs Rust Won't Catch" Gaps

> **Provenance note - read this first.** Like its companion audit,
> this document is an **inherited donor-project artifact**: the
> completed, work-item-by-work-item runbook the donor project (a
> Windows NTFS file-search tool) used to close every gap that audit
> found.  All file paths, crate names, PR numbers, and statuses below
> refer to the donor codebase - none of that code exists in this
> template.  It is kept as a worked example of how to structure a
> hardening runbook: stable WI IDs, per-WI goal/files/steps/acceptance/
> tests/verify, a tracking table, phase ordering, and regression
> guardrails.  Copy the *shape*, not the contents, when your project
> needs one.

**Branch:** `harden/bugs-rust-wont-catch` (donor)
**Companion audit:** [`bugs-rust-wont-catch-audit.md`](./bugs-rust-wont-catch-audit.md)
**Goal:** 100% coverage/mitigation of every bug category from the corrode.dev
article *Bugs Rust Won't Catch*, with regression guardrails so the gaps cannot
silently return.

---

## 0. How to use this document (read first)

This is a **step-by-step runbook for a junior engineer**. Work top-to-bottom.
Each unit of work is a **Work Item (WI)** with a stable ID like `WI-2.1`. For
every WI you will find:

- **Goal** - one sentence on what "done" looks like.
- **Files** - exact paths you will touch.
- **Steps** - numbered, copy-pasteable changes.
- **Acceptance criteria** - objective checks; all must pass.
- **Tests** - the test(s) you must add/update (we never reduce coverage).
- **Verify** - the exact commands to run.

### Working rules (non-negotiable - from the donor repo's user rules)

1. **One WI = one commit.** Commit message: `fix(security): <root cause>` /
   `refactor(mft): <root cause>` etc. Small, atomic commits.
2. **No suppression hacks.** Do not add blanket `#[allow(...)]`, do not disable
   lints, do not comment out tests. A scoped `#[expect(lint, reason = "…")]` is
   allowed only when truly necessary and must carry a justification.
3. **Production code must stay lint-clean.** Every new private item needs a doc
   comment (`missing_docs_in_private_items` is denied). No `unwrap`/`expect`/
   `panic`/`indexing`/`as`-cast in prod code (all denied).
4. **Match surrounding style.** No verbose explanatory comments beyond repo norms.
5. **Update the tracking table** (§1) the moment a WI's status changes.
6. **Keep a healing log.** Append progress to
   `LOG/<YYYY_MM_DD_HH_MM>_CHANGELOG_HEALING.md` per the repo user rules.

### Verification policy (baseline & final use the CI pipeline)

- **Before you start** and **after each phase**, run the full pipeline as the
  source of truth:
  ```bash
  just go                       # safe validation: fmt + lint + test + coverage
  # or, equivalently:
  rust-script scripts/ci/ci-pipeline.rs go -v
  ```
- **Between** WIs, iterate faster with local advisory checks:
  ```bash
  just check                    # quick build+lint, no coverage
  cargo nextest run -p <crate>  # focused tests
  just lint-prod                # ultra-strict prod lint
  just lint-tests               # test-code lint
  ```
- A WI is **not** "Done" until `just go` is green **and** its acceptance
  criteria are met. Do **not** bump versions / deploy / push (that is the
  `just phase2-ship` lane and requires explicit maintainer approval).

### Phase ordering (do them in this order - later phases depend on earlier)

1. **Phase A - Security primitives** (WI-2.x, WI-1.x): shared secure-fs helpers;
   everything else reuses them.
2. **Phase B - Lints & guardrails** (WI-5.1, WI-G.1): turn on the missing lints
   and the regression grep-gate early so new code is born compliant.
3. **Phase C - Byte-boundary correctness** (WI-4.x).
4. **Phase D - Parser hardening & fuzzing** (WI-5.2, WI-5.3).
5. **Phase E - Errors, trust boundary, parity, identity** (WI-6.x, WI-8.x,
   WI-7.x, WI-3.x).

---

## 1. Progress tracking

**Status legend:** ⬜ Not started · 🟦 In progress · ✅ Done (acceptance met +
`just go` green) · ⛔ Blocked · 🟨 Deferred (tracked, see notes).

Update the **Status**, **Commit**, and **Verified** columns as you go. "Verified"
means the acceptance criteria were checked off *and* the pipeline was green.

### 1.1 Work-item tracker

| WI | Category | Description | Status | Commit | Verified |
|----|----------|-------------|:------:|--------|:--------:|
| WI-2.1 | 2 Perms | Add `create_new_secure_file` + `write_secret_file` helpers in `acmex-security::fs` | ✅ | `harden/bugs` | ✅ |
| WI-2.2 | 2 Perms | `create_secure_dir`: per-component `0700` via `DirBuilderExt::mode` | ✅ | `harden/bugs` | ✅ |
| WI-2.3 | 2 Perms | Keystore: write `key.bin` / DPAPI blob born `0600` (no chmod-after) | ✅ | `harden/bugs` | ✅ |
| WI-2.4 | 2 Perms | `atomic_write`: temp born `0600` + randomised name (also feeds WI-1.2) | ✅ | `harden/bugs` | ✅ |
| WI-1.1 | 1 TOCTOU | `secure_remove`: single fd (open once, `file.metadata()`) | ✅ | `harden/bugs` | ✅ |
| WI-1.2 | 1 TOCTOU | Randomised, `create_new` temp in `atomic_write` + daemon `--out` export | ✅ | `harden/bugs` | ✅ |
| WI-5.1 | 5 Panic | Enable `arithmetic_side_effects`; `overflow-checks=true` for `dist` | ✅ | `harden/bugs` | ✅ |
| WI-G.1 | Guard | CI grep-gate script forbidding the anti-patterns from returning | ✅ | `harden/bugs` | ✅ |
| WI-4.1 | 4 Bytes | Single instrumented UTF-16 decoder; per-index `lossy_name_count` stat + warn | ✅ | `harden/bugs-2` | ✅ |
| WI-4.2 | 4 Bytes | Pass `OsString` (not `to_string_lossy`) to spawn argv / IPC paths | ✅ | `harden/wi-4.2-osstring-argv` | full `&[OsString]` spawn chain (incl. Windows `CreateProcessW`/`ShellExecuteW` via `encode_wide`) + 4 `from_utf16_lossy` decode sites (2 lossless, 2 AUDIT-OK); gate now fully green |
| WI-4.3 | 4 Bytes | Strict-parse subprocess stdout used for decisions (PID/name) | ✅ | `harden/bugs` | ✅ |
| WI-4.4 | 4 Bytes | **RFC + impl:** lossless name storage (binary/WTF-8 column) | ✅ | #358 + `feat/malformed-name-forensics` | bytes-native `MftIndex.names: Vec<u8>` (WTF-8) + `get_name_bytes` / `CompactRecord::name_bytes`; lossless `wtf8_from_utf16le`; cache v14/v11 bump; surrogate-named file is enumerated + byte-recoverable (not hidable). Storage landed in **#358**. Forensic surface (`--malformed`/`--well-formed`/`--malformed-path` filters + `malformed`/`malformed_path`/`name_hex` columns) added on `feat/malformed-name-forensics`, which also fixed two real ways a crooked name could still hide (crooked-dir path truncation in `resolve_path_cached_with_malformed`; `numeric_top_n` empty-lossy-name skip). RFC §8 records the bytes-native design. Live-Windows find+open is now scripted (`create-corrupted-name-tree.rs --verify`) - one elevated run pending (see §5). |
| WI-5.2 | 5 Panic | Replace parser arithmetic with `checked_*`; remove parser `indexing_slicing` allows → `.get()` | ✅ | PR #349 (merged) | ✅ |
| WI-5.3 | 5 Panic | In-tree malformed-input fuzz/regression tests (parsers + cache deserialize) | ✅ | `harden/wi-5.3-malformed-tests` | parser malformed-record test (PR #349) + deserializer truncation/boundary/seeded-fuzz corpus |
| WI-6.1 | 6 Errors | `daemon_ctl` control writes: surface/log instead of bare `drop` | ✅ | `harden/bugs` | ✅ |
| WI-6.2 | 6 Errors | Log dir-create failures (`log_init`, `mft/logging`) to stderr once | ✅ | `harden/bugs` | ✅ |
| WI-6.3 | 6 Errors | Audit remaining `.ok()`/`let _ =`; add justification comments | ✅ | `harden/bugs-2` | ✅ |
| WI-8.1 | 8 Trust | Broker: thread one process handle verify→`DuplicateHandle` (no PID re-open) | ✅ | `harden/wi-8.1-broker-single-handle` | single `OpenProcess` via RAII `OwnedProcessHandle`; verify + duplicate share it; `broker/process_handle.rs` split; name-predicate unit tests |
| WI-8.2 | 8 Trust | Document daemon-nonce security property (depends on WI-2.2) | ✅ | `harden/bugs` | ✅ |
| WI-7.1 | 7 Parity | Parity corpus: pathological names; assert vs Windows enumeration | ✅ | `harden/wi-7.1-parity-corpus` | Tier-1 decoder pins (CI) + Tier-2 offline-capture-vs-`cpp_*.txt` golden (env-gated, validated on real capture: 15049 paths matched, ADS + hard-link diffs asserted); corpus generator extended |
| WI-3.1 | 3 Identity | `paths_identical` (dev,inode) helper + invariant doc/test for scoping | ✅ | `harden/bugs` | ✅ |

### 1.2 Category coverage rollup (fill as phases close)

> **Status (effort complete):** all 20 work items are ✅, landed across
> PRs #345–#358 (Phase-A foundation `harden/bugs*` plus WI-4.2 #351, WI-5.2
> #349, WI-5.3 #350, WI-8.1 #352, WI-7.1 #353, the WI-G.1 pipeline wiring
> #354, and the WI-4.4 lossless-name storage #358). WI-4.4's *elimination*
> half is now **implemented** (surrogate-named files can no longer hide), and
> its forensic surface - `--malformed`/`--well-formed`/`--malformed-path`
> filters plus `malformed`/`malformed_path`/`name_hex` columns, and two further
> crooked-name hiding fixes - lands on `feat/malformed-name-forensics` (PR
> pending; see §5). The only open item is the elevated-Windows `--verify` run.
> The §2 "Definition of done" is therefore **met**.

| # | Category | Mitigation definition (acceptance) | WIs | Coverage |
|---|----------|------------------------------------|-----|:--------:|
| 1 | TOCTOU | No check→use on re-resolved paths; no predictable temp + `File::create` | 1.1, 1.2, 2.4 | **100%** |
| 2 | Perms-after-create | Every secret/dir **born** with final perms; zero chmod-after on secrets | 2.1–2.4 | **100%** |
| 3 | Path string identity | No safety decision on path strings; identity helper exists + tested | 3.1 | **100%** |
| 4 | UTF-8 byte boundary | Zero **silent** lossy conversions; argv/IPC use `OsString`; lossless storage RFC landed | 4.1–4.4 | **100%** for "non-silent + measured + argv/IPC correct" (4.1 instrumented decoder ✅, 4.2 `OsString` argv ✅, 4.3 strict-parse ✅, 4.4 RFC ✅; anti-pattern gate green). 4.4 *elimination* tracked separately as a 🟨 follow-up per §2 DoD. |
| 5 | Panic = DoS | Missing lints on; parsers `.get()` + `checked_*`; fuzz tests green | 5.1–5.3 | ✅ 100% (5.1 ✅; 5.2 ✅ all 5 parsers hardened + module-scoped `arithmetic_side_effects`; 5.3 ✅ parser malformed-record test + deserializer truncation/boundary/seeded-fuzz corpus) |
| 6 | Discarded errors | No bare `drop(write/flush)`; every intentional discard commented | 6.1–6.3 | **100%** (6.1 control writes surfaced ✅, 6.2 dir-create failures logged ✅, 6.3 `.ok()`/`let _` audit + justification comments ✅) |
| 7 | Bug-for-bug parity | Parity test covers pathological names; runs in CI | 7.1 | **100%** (7.1 ✅: Tier-1 decoder pins in CI + Tier-2 offline-capture-vs-golden, validated on real capture) |
| 8 | Resolve before trust boundary | One process handle threads verify→grant; nonce property documented | 8.1, 8.2 | **100%** (8.1 ✅ single `OpenProcess` RAII handle threaded verify→duplicate; 8.2 ✅) |
| G | Regression guard | Grep-gate in CI blocks reintroduction of all anti-patterns | G.1 | **100%** (gate fully green + **wired into the pipeline**: runs as "Anti-pattern gate" in `phase1_fanout_validation`, enforced by `just go` / ship) |

> **Note on WI-4.4 (🟨 Deferred-but-tracked):** literal *lossless* name handling
> requires a binary/WTF-8 name column that ripples through the Polars query
> engine, compact storage, and serialization. It is too large to land blind, so
> it ships as an RFC first (acceptance below). WI-4.1 makes the current loss
> **non-silent, measured, and tested** - that is the required mitigation; WI-4.4
> is the path to elimination and must not be silently dropped.
>
> **Update (2026-06-05):** implemented. WI-4.4 shipped **bytes-native** (not the
> RFC's sidecar Option B) in #358; the forensic filter/column surface and two
> crooked-name hiding fixes land on `feat/malformed-name-forensics`. Only the
> elevated-Windows `--verify` run remains (see §5).

> **Deviation (WI-5.1 - implementation reality):** the plan called for a
> workspace `arithmetic_side_effects = "warn"`. That is **not viable** in this
> repo: the lint gate runs `-D warnings` (`just/shared.just::common_flags`),
> which promotes a workspace `"warn"` to a hard error across ~1766 legitimate
> sites (timestamp math, chunking, compact-cache offsets, crypto) far beyond
> the untrusted-input parsers the lint targets. Resolution: WI-5.1 ships the
> unambiguous half (`[profile.dist] overflow-checks = true`); the lint itself
> is enabled **module-scoped** (`#![warn(clippy::arithmetic_side_effects)]`) on
> the MFT parser modules in WI-5.2, where wrapping on raw on-disk bytes is the
> real DoS risk, and those sites are converted to `checked_*`. Net effect for
> Category 5 is identical (parsers guarded), without 1766 false-positive gate
> failures.

---

## Phase A - Security primitives (Categories 2 & 1)

All file paths below are relative to the repo root. The canonical "correct"
reference already in the tree is
`crates/acmex-security/src/runtime_dir.rs` (`UnixRuntimeDir::create_owner_only`,
lines ~298-310): `OpenOptions::new().read(true).write(true).create_new(true)
.mode(0o600).open(path)`. We are generalising that pattern.

### WI-2.1 - Add shared secure-create helpers in `acmex-security::fs`

**Goal:** one place that creates a file **born** with owner-only perms and that
**refuses to follow or reuse** an existing path (kills symlink pre-planting).

**Files:** `crates/acmex-security/src/fs.rs`

**Steps:**

1. At the top of `fs.rs`, the imports are currently `use std::io;` and
   `use std::path::Path;`. Leave them.
2. Add the following two public functions (place them just below the
   "Directory & File Permissions" section header, before `create_secure_dir`).
   Keep the existing Windows attribute helpers; reuse them for the Windows arm.

   ```rust
   /// Create a brand-new file with owner-only permissions, failing if the
   /// path already exists (including as a dangling symlink).
   ///
   /// On Unix the file is born `0o600` via `O_CREAT | O_EXCL` + `mode()`, so
   /// there is never a window where it is world-readable (cf.
   /// `set_permissions`-after-create). On Windows `create_new` likewise refuses
   /// to follow/replace an existing path; owner-only ACL is applied immediately.
   ///
   /// # Errors
   ///
   /// Returns [`io::ErrorKind::AlreadyExists`] if the path exists, or any other
   /// error from the underlying open.
   pub fn create_new_secure_file(path: &Path) -> io::Result<std::fs::File> {
       #[cfg(unix)]
       {
           use std::os::unix::fs::OpenOptionsExt as _;
           std::fs::OpenOptions::new()
               .write(true)
               .create_new(true)
               .mode(0o600)
               .open(path)
       }
       #[cfg(windows)]
       {
           let file = std::fs::OpenOptions::new()
               .write(true)
               .create_new(true)
               .open(path)?;
           // Apply owner-only ACL immediately (best-effort, same as elsewhere).
           if !win_set_owner_only_acl(path) {
               win_set_hidden(path);
           }
           Ok(file)
       }
   }

   /// Write `data` to a **new** secret file born with owner-only permissions.
   ///
   /// Refuses to overwrite an existing path; callers that intend to replace an
   /// existing secret must remove it first (so a symlink cannot be followed).
   ///
   /// # Errors
   ///
   /// Returns an error if creation, writing, or syncing fails.
   pub fn write_secret_file(path: &Path, data: &[u8]) -> io::Result<()> {
       use std::io::Write as _;
       let mut file = create_new_secure_file(path)?;
       file.write_all(data)?;
       file.sync_all()?;
       Ok(())
   }
   ```

**Acceptance criteria:**

- `cargo doc -p acmex-security` builds (doc comments present; `missing_docs`
  clean).
- `just lint-prod` is clean for `acmex-security`.

**Tests:** add to `crates/acmex-security/src/fs.rs` test module (or the existing
secure-fs test file):

- `create_new_secure_file_is_0600` (Unix): create a temp path, assert the
  returned file's `metadata().permissions().mode() & 0o777 == 0o600`.
- `create_new_secure_file_rejects_existing`: pre-create the path; assert the call
  returns `AlreadyExists`.
- `create_new_secure_file_rejects_symlink` (Unix): create a symlink at the path
  pointing elsewhere; assert the call errors and the symlink target is untouched.

**Verify:** `cargo nextest run -p acmex-security`

---

### WI-2.2 - `create_secure_dir`: born-`0700` per component

**Goal:** no window where the runtime/cache dir (holds key, cache, socket,
nonce) exists at default perms.

**Files:** `crates/acmex-security/src/fs.rs` (`create_secure_dir`, lines ~36-54).

**Steps:**

1. Replace the Unix arm body. Current:
   ```rust
   std::fs::create_dir_all(path)?;
   #[cfg(unix)]
   return {
       use std::os::unix::fs::PermissionsExt as _;
       std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
   };
   ```
   New (Unix arm creates every component already at `0700`):
   ```rust
   #[cfg(unix)]
   return {
       use std::os::unix::fs::DirBuilderExt as _;
       std::fs::DirBuilder::new()
           .recursive(true)
           .mode(0o700)
           .create(path)
   };
   ```
2. Keep the Windows arm as-is (it already calls `create_dir_all` then sets the
   ACL; leave `create_dir_all(path)?` *inside the Windows arm only*). Restructure
   so `create_dir_all` is no longer called unconditionally before the `cfg`
   branches - move it into the Windows `return { … }` block.
3. Note in the doc comment: `recursive(true)` makes `create` succeed if the dir
   already exists; existing components keep their current perms (we only
   guarantee birth perms for components we create).

**Acceptance criteria:**

- No `set_permissions` call remains in `create_secure_dir`.
- Unix: a freshly created nested dir reports mode `0700`.

**Tests:** `create_secure_dir_births_0700` (Unix): create `tmp/a/b/c`; assert each
created component's mode is `0700`. `create_secure_dir_idempotent`: calling twice
returns `Ok`.

**Verify:** `cargo nextest run -p acmex-security`

---

### WI-2.3 - Keystore writes the key born-`0600`

**Goal:** the AES key / DPAPI blob is never on disk at default perms.

**Files:** `crates/acmex-security/src/keystore.rs`
(`file_based_key` ~373-409; `dpapi_write_key` ~189-195).

**Steps:**

1. In `file_based_key`, replace:
   ```rust
   std::fs::write(&key_path, key)?;
   crate::fs::set_file_permissions_owner_only(&key_path)?;
   ```
   with:
   ```rust
   // Replace any stale key first so create_new can't follow a planted symlink.
   if key_path.exists() {
       let _ignore = std::fs::remove_file(&key_path);
   }
   crate::fs::write_secret_file(&key_path, &key)?;
   ```
   (The "wrong size" branch above already logs and falls through to regenerate;
   the `remove_file` makes the subsequent `create_new` deterministic.)
2. In `dpapi_write_key` (Windows), replace the `std::fs::write` +
   `set_file_permissions_owner_only` pair with the same
   `remove_file`-then-`write_secret_file(path, &encrypted)` shape.

**Acceptance criteria:**

- No `std::fs::write` for key material remains in `keystore.rs`.
- Unix: after first run, `key.bin` mode is `0600`; no observable window at a
  wider mode (covered structurally by `create_new` + `mode`).

**Tests:** `key_bin_is_0600_on_first_gen` (Unix, dev-mode/file-based path): point
the data dir at a temp dir (via the existing test seam, or
`dirs_next`), call `get_cache_key()`, assert the on-disk key file mode is
`0600`. Reuse/extend the existing keystore tests at lines ~439-450.

**Verify:** `cargo nextest run -p acmex-security`

---

### WI-2.4 + WI-1.2 - `atomic_write`: born-`0600` temp with a randomised name

**Goal:** remove both the perms-after-create window **and** the predictable,
symlink-pluggable temp name in the shared atomic-write primitive (and in the
daemon `--out` export that copies the pattern).

**Files:** `crates/acmex-security/src/fs.rs` (`atomic_write`, ~212-226);
`crates/acmex-daemon/src/index/search.rs` (`write_rows_to_file`, ~685-724).

**Steps (atomic_write):**

1. Build a unique temp name in the **same directory** as `path` (same-FS rename
   stays atomic). `acmex-security` already depends on `rand` (used by keystore).
   ```rust
   use rand::Rng as _;
   let suffix: u64 = rand::rng().random();
   let file_name = path.file_name().unwrap_or_default();
   let tmp_name = format!("{}.{:016x}.acmex.tmp", file_name.to_string_lossy(), suffix);
   let tmp_path = path.with_file_name(tmp_name);
   ```
   (Note: `unwrap_or_default` here is on `Option`, not `Result`; it is *not* an
   `unwrap()` lint violation. Confirm with `just lint-prod`.)
2. Replace `let mut file = std::fs::File::create(&tmp_path)?;` with
   `let mut file = create_new_secure_file(&tmp_path)?;`.
3. Remove the now-redundant `set_file_permissions_owner_only(&tmp_path)?;` line
   (the temp is already `0600`).
4. On any error after creation, remove the temp before returning (add an
   error-cleanup path mirroring the daemon code).

**Steps (daemon `--out` export, search.rs):**

1. Replace the predictable `target.with_extension("acmex.tmp")` + `File::create`
   with the same randomised-name + `acmex_security::fs::create_new_secure_file`
   approach. The crate already depends on `acmex-security`.
2. Keep the existing error-cleanup `remove_file(&tmp_path)` and the final
   `rename`.

**Acceptance criteria:**

- No `File::create` on a deterministic, caller-derived temp path remains in
  either file.
- The grep-gate (WI-G.1) for `with_extension("acmex.tmp")` + `File::create`
  reports zero hits.

**Tests:**

- `atomic_write_sets_0600` (Unix): write via `atomic_write`, assert final file
  mode `0600`.
- `atomic_write_concurrent` : spawn N threads writing the same target; assert no
  panic and the final content equals one of the writers' payloads (randomised
  temps must not collide).
- Daemon: extend an existing `write_rows_to_file` test to assert the produced
  file exists with expected content and that a pre-planted symlink at a *guessed*
  temp name is not followed (best-effort; randomised name makes the guess fail).

**Verify:** `cargo nextest run -p acmex-security && cargo nextest run -p acmex-daemon -- write_rows`

---

### WI-1.1 - `secure_remove`: anchor on a single fd

**Goal:** the size used to zero-overwrite and the bytes written go through the
**same** handle; do not re-resolve the path or follow symlinks.

**Files:** `crates/acmex-security/src/fs.rs` (`secure_remove`, ~244-289).

**Steps:**

1. Replace the initial `std::fs::metadata(path)` check + later
   `OpenOptions::new().write(true).open(path)` with a single open, then read the
   length from the open file:
   ```rust
   // Open first (anchor on the fd); NotFound is a no-op as before.
   let mut file = match std::fs::OpenOptions::new().write(true).read(true).open(path) {
       Ok(f) => f,
       Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
       Err(err) => return Err(err),
   };
   let file_len = file.metadata()?.len();
   ```
2. Keep the Windows `win_clear_readonly(path)?` call **before** the open (a
   read-only file can't be opened for write); document that this is a path-based
   attribute clear that precedes the anchor - acceptable because it only toggles
   an attribute, not content.
3. The zero-fill loop and `remove_file(path)` at the end stay. (The final
   `remove_file` is by path; that is inherent to unlink and acceptable.)

**Acceptance criteria:**

- Only **one** `open` of `path` for writing; no `std::fs::metadata(path)` stat
  before it.

**Tests:** `secure_remove_zeroes_then_unlinks`: create a file with known bytes,
`secure_remove`, assert it no longer exists. `secure_remove_absent_is_ok`: call on
a missing path → `Ok`. (Symlink-follow assertion: create a symlink to a sentinel
file, `secure_remove(symlink)`; assert sentinel **content** preserved - only the
link removed - or document the chosen semantics.)

**Verify:** `cargo nextest run -p acmex-security`

---

## Phase B - Lints & regression guardrails

### WI-5.1 - Enable the missing arithmetic lint + dist overflow checks

**Goal:** the one lint from the article that is off (`arithmetic_side_effects`)
becomes a warning, and shipped binaries keep overflow checks.

**Files:** `Cargo.toml` (`[workspace.lints.clippy]` ~316; `[profile.dist]`).

**Steps:**

1. In `[workspace.lints.clippy]`, add (place near `indexing_slicing`):
   ```toml
   arithmetic_side_effects = "warn"   # Untrusted-input arithmetic must use checked_*/saturating_*
   ```
   Use `"warn"` (not `"deny"`) initially: the parsers will trip it until WI-5.2
   lands. Once WI-5.2 is done, raise to `"deny"` in a follow-up commit and record
   it in the tracker.
2. In `[profile.dist]`, add `overflow-checks = true` (matches `release` intent
   for a shipped product; measure the perf delta - if material, document and keep
   `release` off but `dist` on, or gate behind a feature).
3. Confirm test code is exempt: the crate roots already carry the
   `#![cfg_attr(test, allow(...))]` pattern per `clippy.toml`; if a test trips
   `arithmetic_side_effects`, add it to that test-scoped allow list - **not** a
   blanket allow.

**Acceptance criteria:** `just check` shows `arithmetic_side_effects` warnings
*only* in the parser modules slated for WI-5.2 (record them), and nowhere else.
`[profile.dist]` contains `overflow-checks = true`.

**Verify:** `just check 2>&1 | rg arithmetic_side_effects`

---

### WI-G.1 - Regression grep-gate (prevents the anti-patterns returning)

**Goal:** CI fails if any anti-pattern from the audit is reintroduced. This is
what makes coverage *stay* at 100%.

**Files:** new `scripts/ci/anti_pattern_gate.sh` (or `.rs` rust-script to match
the existing `scripts/ci/` style); wire into the pipeline.

**Steps:**

1. Create the script. It greps `crates/**/src/**` excluding `*test*` and fails
   (exit 1) on any match, printing file:line. Patterns to forbid in **prod**
   code:
   - `from_utf16_lossy` and `from_utf8_lossy` - must route through the approved
     instrumented decoder (WI-4.1) or carry an inline `// AUDIT-OK(bytes): <why>`
     marker.
   - `\.with_extension\("acmex\.tmp"\)` paired with `File::create` - predictable
     temp.
   - `set_permissions\(` in `acmex-security` outside the legacy compat helper -
     perms-after-create.
   - `std::fs::write\(` of key material in `keystore.rs`.
   - `drop\((?:stream|pipe)\.(?:write_all|flush)` - discarded control writes.
   The script honours an explicit `// AUDIT-OK(<category>): <reason>` escape
   comment on the same or previous line, so deliberate, justified exceptions are
   visible and greppable.
2. Add a `just` recipe `audit-gate` in `just/security.just` that runs the script,
   and call it from the `go` lane (or `scripts/ci/ci-pipeline.rs`).

**Acceptance criteria:** running `just audit-gate` on the **pre-fix** tree fails
with the known hits; after all WIs land it passes; adding a fresh
`from_utf16_lossy` to any prod file makes it fail.

**Tests:** a tiny fixture test (a temp file containing a forbidden token) that the
gate flags it - or a documented manual check in the script header.

**Verify:** `just audit-gate`

**Pipeline wiring (landed once the gate went green):** the gate is invoked as the
**"Anti-pattern gate"** parallel command in
`scripts/ci-pipeline/src/phases.rs::phase1_fanout_validation` (alongside the
clippy trio, `cargo deny`, doctests, rustdoc), so `just go` / `just ship`
Phase 1 fail if any anti-pattern returns. Verified end-to-end:
`cargo run -p acmex-ci-pipeline -- phase1` shows `✅ Anti-pattern gate (2s)`.

---

## Phase C - Byte-boundary correctness (Category 4)

### WI-4.1 - One instrumented UTF-16 decoder; make loss observable

**Goal:** every NTFS-name decode goes through a single function that **counts**
replacement substitutions, surfaces the count in index stats, and logs a warning
when > 0. No more silent corruption.

**Files:**
- `crates/acmex-mft/src/io/parser/unified.rs` (`decode_utf16le_into`, ~29-76) -
  the canonical decoder.
- All other decode sites listed in the audit §4.1:
  `fragment.rs:144`, `index.rs:204,353,452`, `index_extension.rs:133,255,307`,
  `fragment_extension.rs:98,172`.
- `crates/acmex-mft/src/index/stats.rs` (add a counter field).

**Steps:**

1. Change `decode_utf16le_into` to return the number of U+FFFD substitutions it
   emitted (currently returns `()` despite the doc claiming it returns a count):
   ```rust
   /// …Returns the number of U+FFFD replacements emitted (0 = lossless).
   fn decode_utf16le_into(bytes: &[u8], out: &mut String) -> u32 {
       out.clear();
       let mut replacements: u32 = 0;
       // …each `out.push(char::REPLACEMENT_CHARACTER);` site:
       //   replacements = replacements.saturating_add(1);
       // …
       replacements
   }
   ```
2. Add a public helper alongside it so other parser files share one
   implementation instead of `String::from_utf16_lossy`:
   ```rust
   /// Decode a UTF-16LE name into a fresh `String`, returning the replacement
   /// count. Use this instead of `String::from_utf16_lossy` at NTFS boundaries
   /// so loss is counted, not silent.
   pub(crate) fn decode_name_utf16le(bytes: &[u8]) -> (String, u32) {
       let mut s = String::new();
       // bytes here are already u16 LE pairs; if a callsite has Vec<u16>,
       // add a sibling `decode_name_u16(&[u16]) -> (String, u32)`.
       let n = decode_utf16le_into(bytes, &mut s);
       (s, n)
   }
   ```
   For the callsites that currently build a `Vec<u16>`/`SmallVec<[u16;64]>` and
   call `String::from_utf16_lossy`, add a `decode_name_u16(&[u16]) -> (String,
   u32)` variant to avoid re-deriving the byte slice.
3. Replace **every** `String::from_utf16_lossy(...)` in the parser files with the
   shared helper, accumulating the replacement count into the per-record / index
   stat.
4. In `index/stats.rs`, add `pub lossy_name_count: u64` (init `0`, documented),
   increment it as records are processed, and include it wherever stats are
   logged/summarised.
5. Emit one `tracing::warn!(lossy_name_count, drive, "N filenames contained
   characters not representable in UTF-8 and were stored with U+FFFD")` at the
   end of an index build when the count is non-zero.

**Acceptance criteria:**

- Zero `String::from_utf16_lossy` calls remain in `crates/acmex-mft/src/io/parser`
  (grep-gate WI-G.1 enforces this).
- A record whose name contains an unpaired surrogate increments
  `lossy_name_count` and produces a name containing `\u{FFFD}`.

**Tests:** in the parser test module, craft a `$FILE_NAME` byte buffer with an
unpaired high surrogate (`0x00D8` LE = `D8 00`) and assert: (a) parsing succeeds,
(b) the decoded name contains `char::REPLACEMENT_CHARACTER`, (c) the returned
replacement count is `1`, (d) `stats.lossy_name_count` increased. Add a
round-trip lossless test for a normal BMP + astral name (count `0`).

**Verify:** `cargo nextest run -p acmex-mft -- decode` and `-- lossy`

---

### WI-4.2 - Pass `OsString` to spawn argv / IPC instead of `to_string_lossy`

**Goal:** spawning the daemon / passing paths over IPC never mangles a non-UTF-8
(or WTF-8 on Windows) path.

**Files (path→argv sites from audit §4.2):**
`crates/acmex-cli/src/commands/daemon_mgmt.rs:93,97,156`;
`crates/acmex-cli/src/main.rs:489,492`;
`crates/acmex-mcp/src/process.rs:19,23,267,270`;
`crates/acmex-client/src/daemon_spawn.rs` (where it builds argv).

**Steps:**

1. Where the code does `args.push(path.to_string_lossy().into_owned())` and the
   container is `Vec<String>`, change the container to `Vec<OsString>` and push
   `path.as_os_str().to_os_string()` (or `path.into()`), then pass the vec to
   `Command::args` (which accepts `IntoIterator<Item: AsRef<OsStr>>`).
2. For the **Windows custom CreateProcess** path in `daemon_spawn.rs` that builds
   a single command line string (`quote_arg_for_createprocess`), the command line
   must be UTF-16 anyway - build it from `OsStr` via `encode_wide` rather than via
   `to_string_lossy()` → `String`. If that is too invasive for this pass, leave a
   `// AUDIT-OK(bytes): CreateProcess command line is UTF-16; <details>` marker
   and open a follow-up; note it in the tracker.
3. Anywhere a path crosses the IPC wire as a `String` field (handler/protocol),
   confirm the receiving side does not need to re-open it as a path; if it does,
   the wire type should be bytes. Scope this to argv first; wire-path types are
   part of WI-4.4's surface - cross-reference, don't duplicate.

**Acceptance criteria:** no `to_string_lossy()` on a path that is then used as a
spawn argument remains (grep `to_string_lossy` in the listed files → only
display/log uses remain, each marked `// AUDIT-OK(bytes): display only`).

**Tests:** unit test that building the daemon spawn argv from a `PathBuf`
containing a non-UTF-8 byte (Unix: `OsString::from_vec(vec![0x66, 0x80, 0x66])`)
preserves the exact bytes in the resulting `OsString` argv entry.

**Verify:** `cargo nextest run -p acmex-cli -p acmex-client -p acmex-mcp`

**Implementation notes (landed on `harden/wi-4.2-osstring-argv`):**

- **Full `&[&str]`/`&[String]` → `&[OsString]` spawn chain.** The spawn argv now
  carries OS-native bytes end to end: `process::build_daemon_args` (mcp) and the
  two `daemon_mgmt.rs` builders + `extract_spawn_args` (cli) produce
  `Vec<OsString>` (flag literals via `OsString::from`, path values via
  `path.as_os_str().to_os_string()` - no `to_string_lossy`); the public client
  API `AcmexClient`/`AcmexClientSync::connect_with_args`/`connect_with_elevation`,
  `auto_start_daemon`, `log_spawn_details`, and the whole `daemon_spawn.rs`
  chain (`spawn_daemon`, `spawn_daemon_unix`/`_windows`, `spawn_via_uac_prompt`,
  `spawn_detached_no_inherit`, `shell_execute_elevated`) all take `&[OsString]`.
  The `McpConfig`/`HttpGatewayConfig`/`AcmexMcpServer` `daemon_spawn_args` fields
  and the handler `ClientSlot` became `Vec<OsString>` too.
- **Windows `CreateProcessW` / `ShellExecuteW` rewritten to UTF-16.**
  `quote_arg_for_createprocess` now operates on `&[u16]` (was `&str → String`)
  and a shared `build_wide_command_line` builds the command line from
  `OsStr::encode_wide`, so a path with unpaired surrogates / non-UTF-8 bytes
  reaches the child's argv **losslessly** instead of being `to_string_lossy`
  mangled to U+FFFD. The MSVCRT backslash/quote/empty-arg escaping rules are
  preserved (now expressed over code units). The `process.rs` `acmexmcp`-restart
  spawn args switched from `cmd.args(["--data-dir", &dir.to_string_lossy()])` to
  `cmd.arg("--data-dir"); cmd.arg(dir.as_os_str())`.
- **The 4 `from_utf16_lossy` decode sites (clears the gate):** `verify.rs`
  (process exe path → identity check) and `broker.rs` exe-name identity check
  now decode **losslessly** via `OsString::from_wide`; `broker.rs`
  `get_client_exe_path` (audit-log display only - the real check is
  `verify_client`) and `pipe.rs` `pwstr_to_string` (decodes an ASCII-by-spec SID
  string) are marked `// AUDIT-OK(bytes)` with rationale.
- **Verification:** native + `cargo xwin` (Windows) `--all-targets -D warnings`
  clippy clean across acmex-broker/client/security/cli/mcp; 390 tests pass; the
  anti-pattern gate is now **fully green** (no remaining byte sites). New
  `lone_surrogate_arg_survives_losslessly` test proves a 0xD800-bearing arg
  round-trips through the quoting routine unchanged.
- **Deviation from the suggested test:** the plan suggested a Unix
  `OsString::from_vec` non-UTF-8 argv test; the lossless property was instead
  proven at the Windows quoting layer (the platform whose `to_string_lossy`
  path was the actual bug), which is where the conversion logic lives.

---

### WI-4.3 - Strict-parse subprocess stdout used for decisions

**Goal:** lossy decode of child-process output never silently corrupts a value
that drives a trust/targeting decision.

**Files:** `crates/acmex-mcp/src/process.rs:500` (parses a PID);
`crates/acmex-broker/src/broker.rs:261`;
`crates/acmex-client/src/verify.rs:309`.

**Steps:**

1. For the PID parse (`process.rs:500`), replace
   `String::from_utf8_lossy(&out.stdout)...parse()` with
   `std::str::from_utf8(&out.stdout).ok().and_then(|s| s.trim().parse().ok())`
   and treat `None` as "could not determine PID" (return an error / skip), rather
   than parsing a U+FFFD-mangled string.
2. For status/name comparisons used in `verify`/broker decisions, do the same:
   `from_utf8` (strict) → on error, fail closed (treat as "not verified").
3. Where the stdout is purely for human logging (not a decision), leave
   `from_utf8_lossy` and add `// AUDIT-OK(bytes): log/display only`.

**Acceptance criteria:** every `from_utf8_lossy` whose result feeds a comparison,
parse, or branch is converted to strict parse with fail-closed handling; the rest
are marked `AUDIT-OK`.

**Tests:** feed a `verify`/PID helper a byte vector with invalid UTF-8 and assert
it returns the "unverified / unknown" outcome (fail-closed), not a wrong match.

**Verify:** `cargo nextest run -p acmex-mcp -p acmex-client`

---

### WI-4.4 - (RFC, then impl) Lossless name storage  ✅ implemented

> **Implemented (`feat/wi-4.4-lossless-names`).** Done **bytes-native**, not via
> the RFC's Option B sidecar - see `refactor/lossless-name-column-rfc.md` §8 for
> why (the search hot path was already byte-native; the only loss was the
> upstream `MftIndex.names: String`). `MftIndex.names`/`MftIndexFragment.names`
> are now `Vec<u8>` (WTF-8); `get_name` stays a lossy `&str` view, new
> `get_name_bytes` / `CompactRecord::name_bytes` are the lossless accessors;
> `wtf8_from_utf16le` + `store_name_lossless` retain ill-formed names
> byte-faithfully; cache `INDEX_VERSION` 13→14 + `COMPACT_VERSION` 10→11
> (pre-bump caches rebuild). A surrogate-named file is **enumerated and
> byte-recoverable** (cannot hide from search). 11 new tests + 1031/548 existing
> green; native + Windows clippy clean. The live-Windows "create a real
> surrogate file → find+open" check below stays a Windows-CI follow-up.

**Goal:** eliminate name loss entirely (true 100%), not just make it observable.

**Why an RFC first:** the name column is a Polars **UTF-8 `String`** column
(`acmex-polars::columns`; deserialize requires UTF-8 at
`crates/acmex-mft/src/index/storage/deserialize.rs:379,574`). WTF-8 (which can
represent unpaired surrogates) is **not** valid UTF-8, so holding it requires a
**Binary** column and touches: the schema, every filter/sort/aggregate that reads
`name`, compact storage layout + (de)serialization, the trigram/case-fold path,
and all output formatters. This is a cross-cutting change that must not be done
blind.

**Steps:**

1. Write a lossless-name-column RFC (donor: `docs/architecture/refactor/lossless-name-column-rfc.md`) covering:
   chosen representation (Binary/WTF-8 column vs. sidecar "raw name" for the rare
   lossy rows), migration of on-disk cache format (version bump + rebuild path),
   query-engine impact, case-folding on non-UTF-8, output/escaping rules, and a
   measured perf budget.
2. Get maintainer sign-off on the RFC (this WI stays 🟨 until then).
3. Implement behind the cache-format version bump; old caches rebuild from MFT.
4. Acceptance (impl): a file with an unpaired-surrogate name is **findable** by
   its exact name and round-trips back to a working open; `lossy_name_count`
   (WI-4.1) is `0` for such files because nothing is replaced.

**Verify:** `just go` + a Windows integration test that creates an
unpaired-surrogate file and finds/opens it via ACMEX.

---

## Phase D - Parser hardening & fuzzing (Category 5)

### WI-5.2 - Replace parser arithmetic/indexing with checked, fallible access

**Goal:** no on-disk MFT/cache byte sequence can panic the parser (overflow or
out-of-bounds slice) - the daemon runs with `panic = "abort"`, so a panic is a
whole-process DoS.

**Files (from audit §5):**
`crates/acmex-mft/src/io/parser/unified.rs`,
`crates/acmex-mft/src/io/parser/fragment.rs`,
`crates/acmex-mft/src/io/parser/fragment_extension.rs`,
`crates/acmex-mft/src/io/parser/index.rs`,
`crates/acmex-mft/src/io/parser/index_extension.rs`, and any module carrying a
crate-level or block-level `#![allow(clippy::indexing_slicing)]`.

**Steps:**

1. Find every `&buf[a..b]`, `buf[i]`, `a + b`, `a - b`, `a * b`, `len - off` on
   data derived from the record bytes. For each:
   - Slices → `buf.get(a..b).ok_or(ParseError::Truncated)?` (or the crate's
     existing error type - reuse it, don't invent a new one).
   - Indexing → `*buf.get(i).ok_or(...)?`.
   - Arithmetic on offsets/lengths → `a.checked_add(b).ok_or(...)?`,
     `a.checked_sub(b).ok_or(...)?`. Use `saturating_*` only where saturation is
     semantically correct (e.g. a display/clamp), never to silently mask a
     corrupt offset that then indexes.
2. Remove the parser modules' `#![allow(clippy::indexing_slicing)]` (and any
   `arithmetic_side_effects` allow) once the bodies are converted. This is the
   point of WI-5.1's `"warn"` → it now reports nothing in these files.
3. Validate bounds **before** trusting header-declared lengths (e.g. an attribute
   length field that claims more bytes than the record holds): clamp/reject via
   the checked path, return a parse error, and let the caller skip the record -
   never panic.
4. Confirm the caller treats a per-record `ParseError` as "skip this record and
   continue indexing", not "abort the whole drive".

**Acceptance criteria:**

- No `indexing_slicing` / `arithmetic_side_effects` allow remains in the parser
  modules; `just lint-prod` is clean with both lints at `"deny"`.
- After this lands, raise `arithmetic_side_effects` from `"warn"` to `"deny"` in
  `Cargo.toml` (follow-up commit; update tracker).

**Tests:** see WI-5.3 - the fuzz/regression corpus is the proof.

**Verify:** `just lint-prod && cargo nextest run -p acmex-mft`

**Implementation notes (as landed, branch `harden/wi-5.2-parser-checked`):**

- **Deviation from steps 1/3 (error type):** the plan assumed converting to
  `buf.get(..).ok_or(ParseError::Truncated)?`. The five parser entry points
  (`process_record`, `parse_record_to_index`, `parse_extension_to_index`, and
  the deprecated `parse_*_to_fragment` pair) do **not** return a `Result` - their
  established contract is "parse what is valid, skip/leave-default what is not,
  return a `bool`/unit and let the caller continue indexing". Introducing a new
  error type would change that public contract. Instead, every untrusted-`data`
  read was converted to `.get()` / the bounds-safe `rd_u16/rd_u32/rd_u64` helpers
  (which return `0` on OOB), and every byte-derived offset/length to
  `checked_add`/`checked_mul` (or `saturating_*` where overflow is provably
  unreachable, with an inline justification comment). On a malformed field the
  result is **exactly the same skip/default the original `if X+N <= len` guards
  produced** - behaviour-preserving, panic-free. This satisfies the goal (no
  byte sequence panics the parser) and step 4 (caller skips the record).
- **Deviation from step 2 / acceptance (lint mechanism):** rather than removing
  the block-level `indexing_slicing` expects outright, they were **narrowed**:
  all untrusted-`data` slicing now goes through `.get()`, so the only `[]` left
  is on internal arena vectors (`index.records[base_ri]`, `fragment.streams[..]`,
  `frs_to_idx[..]`) keyed by indices this code itself mints - not attacker
  controlled. Each retained expect's `reason` now states this. `arithmetic_side_effects`
  was enabled **module-scoped** (`#![warn(clippy::arithmetic_side_effects)]` in
  each of the five parser files) instead of workspace-wide: at workspace level it
  flags 1766 benign sites which, under `-D warnings`, would be a hard error
  (see audit note at line ~461). Module-scoped + the workspace `-D warnings` makes
  it effectively `deny` **inside the parsers** (any new raw `+`/`*`/`[..]` on a
  byte-derived value fails the build there) - the intended regression guard,
  scoped to where it matters. The workspace `Cargo.toml` `arithmetic_side_effects`
  follow-up (raise to deny globally) remains **not done** for this reason.
- **Behaviour parity checked:** the index/fragment parser families have a known
  pre-existing divergence in the extension-name index formula
  (`existing_name_count + name_idx` vs the legacy `existing_name_count - 1 + name_idx`);
  each file's existing formula was preserved verbatim (only `+`→`saturating_add`),
  so this WI introduces **no** semantic change. All 191 `acmex-mft` tests pass
  (190 pre-existing + the new malformed-record regression test); native and
  `cargo xwin` (Windows) `--all-targets -D warnings` clippy are clean.

---

### WI-5.3 - Malformed-input regression/fuzz tests

**Goal:** lock in WI-5.2 with deterministic tests that feed garbage/truncated
bytes to every parser entry point and the cache deserializer, asserting
`Err`/skip - never panic.

**Files:** `crates/acmex-mft/tests/` (new in-tree integration test, e.g.
`parser_malformed.rs`); optionally a `cargo-fuzz` target under
`crates/acmex-mft/fuzz/` if the repo already uses it (check first - do **not** add
a new toolchain dependency without maintainer sign-off; if absent, ship the
table-driven regression test and note fuzz as a follow-up).

**Steps:**

1. Table-driven test: for each parser public entry (record parse, attribute walk,
   `$FILE_NAME` decode, index/fragment runlist parse) feed:
   - empty input, 1-byte input, truncated-at-each-boundary inputs,
   - a record claiming an attribute length larger than the buffer,
   - a runlist with an out-of-range header nibble,
   - random fuzz vectors with a fixed seed (use the existing `rand` dep with a
     seeded RNG for determinism).
   Assert each returns `Err`/`None`/skip and the call does not panic.
2. Cache deserializer: feed truncated/corrupted serialized bytes to the
   deserialize entry (`crates/acmex-mft/src/index/storage/deserialize.rs`) and
   assert a clean error, not a panic.
3. Run under a config where overflow checks are on (debug test build already
   has them) so silent wraps surface as failures.

**Acceptance criteria:** the test suite includes ≥1 malformed case per parser
entry and the cache deserializer; all return errors without panicking; suite is
deterministic (seeded) and runs in CI.

**Verify:** `cargo nextest run -p acmex-mft -- malformed`

**Implementation notes (landed on `harden/wi-5.2-parser-checked`):**

- **Parsers** - a deterministic, table-driven malformed-record regression test
  (`io::parser::tests::malformed_records_do_not_panic`) feeds 8 crafted records -
  each passing the FILE-record header gate so the attribute loop runs - through
  **all three live parser entry points** (`parse_record_to_index`,
  `process_record`, and the deprecated `parse_record_to_fragment`). The cases
  target every edge WI-5.2 converted: first-attribute-offset past EOF, attribute
  length overrunning the record, `name_length * 2` overflow, non-resident size
  fields past EOF, reparse value-offset past EOF, zero-length attribute (loop
  termination), and a full garbage body. A `RecordBuilder` constructs records by
  append, so the fixture itself is index-free and panic-free.
- **Cache deserializer** (`index/storage/deserialize.rs`, `index/tests_storage.rs`)
  - five tests: a valid-blob round-trip baseline; a **truncation sweep** over a
  *populated* serialized index at every length; empty / 1-byte rejection;
  out-of-range section-length header fields (`u64::MAX` in record-count /
  names-size / links-count → clean error, no overflow/OOB); and a **seeded,
  deterministic fuzz loop** (`ChaCha8Rng::seed_from_u64`, 5 000 iterations)
  mixing bit-flips, random truncation, trailing garbage, and fully random blobs.
- **Property under test** is **liveness** - `deserialize` returns `Ok` *or* `Err`
  but never panics/aborts - except where a specific rejection is provable (tiny
  inputs, a cut inside the fixed header, oversized length fields). The truncation
  sweep deliberately does **not** assert "every prefix is an error": the
  deserializer is intentionally lenient about some trailing/optional sections, so
  a near-complete prefix may legitimately parse `Ok`; asserting otherwise would
  encode a false contract. This was found empirically (a 1570/1610-byte prefix
  parsed) and the test was corrected to match the real, safe behaviour.
- A `cargo-fuzz` target is intentionally **not** added - it would introduce a
  toolchain dependency without sign-off (per the plan's own caveat); the seeded
  `ChaCha8Rng` corpus gives deterministic, CI-friendly fuzz coverage instead.

---

## Phase E - Errors, trust boundary, parity, identity

### WI-6.1 - Surface/log discarded control writes (Category 6)

**Goal:** IPC control writes whose failure means "the command did not happen"
are no longer silently dropped.

**Files:** `daemon_ctl` control-write sites from audit §6 (e.g.
`crates/acmex-client/src/...` / `crates/acmex-daemon/src/...` where a
`stream.write_all(...)` / `flush()` result is `drop`-ped or `let _ =`-ed).

**Steps:**

1. For each control write that affects observable behaviour, propagate the
   `io::Result` to the caller (`?`) or, where the surrounding fn cannot return,
   `tracing::warn!`/`error!` with context so the dropped command is visible.
2. Keep deliberate best-effort discards (e.g. a final shutdown flush where the
   peer is already gone) but annotate each with
   `// AUDIT-OK(errors): best-effort <reason>` so the grep-gate passes and intent
   is explicit.

**Acceptance criteria:** no bare `drop(stream.write_all(...))` /
`drop(...flush())` without an `AUDIT-OK(errors)` justification remains; grep-gate
(WI-G.1) passes.

**Tests:** a unit/integration test where the control channel is closed mid-write
asserts the caller observes an error / a warning is emitted (capture via a test
tracing subscriber), not silent success.

**Verify:** `cargo nextest run -p acmex-client -p acmex-daemon -- ctl`

---

### WI-6.2 - Log directory-create failures once (Category 6)

**Goal:** `log_init` / MFT logging setup failures are visible on stderr instead
of vanishing.

**Files:** the `log_init` / `mft/logging` dir-create sites from audit §6.

**Steps:**

1. Where `create_dir_all`/`create_secure_dir` for a log dir is `let _ =`-ed,
   capture the error and `eprintln!` once (logging isn't up yet, so stderr is the
   only honest channel). Do not abort startup if logging dir fails - degrade
   gracefully, but say so.

**Acceptance criteria:** a forced dir-create failure (e.g. path is a file) prints
exactly one stderr diagnostic; startup continues.

**Tests:** unit test pointing the log dir at an un-creatable path asserts the
diagnostic is produced and the init returns the degraded outcome.

**Verify:** `cargo nextest run -- log_init`

---

### WI-6.3 - Audit remaining `.ok()` / `let _ =`; justify each

**Goal:** every intentional error discard in prod code is either fixed or carries
a one-line justification, so reviewers can trust them.

**Files:** workspace-wide prod code (`crates/**/src/**`, excluding tests).

**Steps:**

1. `rg -n "\.ok\(\);|let _ = " crates/*/src` (exclude tests). Triage each:
   - failure changes observable behaviour → propagate/log (as WI-6.1/6.2).
   - genuinely fire-and-forget → add `// AUDIT-OK(errors): <reason>`.
2. Record the final count of `AUDIT-OK(errors)` markers in the tracker note.

**Acceptance criteria:** no un-annotated `.ok()`/`let _ =` discard of a
behaviour-affecting `Result` remains in prod code.

**Verify:** `just lint-prod` + manual triage list attached to the WI commit.

---

### WI-8.1 - Broker: thread one process handle from verify → grant (Category 8)

**Goal:** close the verify-then-reopen-by-PID gap - the handle whose identity is
verified is the **same** handle the privileged volume handle is duplicated into,
so a PID-reuse race cannot redirect the grant.

**Files:** `crates/acmex-broker/src/broker.rs` (client verify + `DuplicateHandle`
path).

**Steps:**

1. Open the client process handle **once** (`OpenProcess` with the minimal rights
   needed for both `QueryFullProcessImageName` verification and `DuplicateHandle`
   target).
2. Perform identity verification (image path / signature / allowlist) on **that**
   handle.
3. Pass the **same** handle to `DuplicateHandle` as the target. Do not re-derive
   from PID between the two steps.
4. Close the handle in all paths (RAII wrapper if one exists in the crate).

**Acceptance criteria:** there is exactly one `OpenProcess`/handle acquisition per
grant; no second PID→handle resolution exists between verify and duplicate.

**Tests:** Windows-gated (`#[cfg(windows)]`, likely `#[ignore]` for elevated
manual run) test exercising the single-handle path; on non-Windows, a structural
unit test/refactor assertion (e.g. the function signature now takes/returns the
handle) documents the invariant.

**Verify:** `cargo nextest run -p acmex-broker` (Windows, elevated for the ignored
case).

**Implementation notes (landed on `harden/wi-8.1-broker-single-handle`):**

- **One `OpenProcess` per grant.** Before this WI the broker opened the client
  process by PID **three times** - `get_client_exe_path` (audit name),
  `verify_client` (identity decision), and `duplicate_volume_handle_to_client`
  (the `DuplicateHandle` target). The window between verify and duplicate was a
  PID-reuse race: a recycled PID could point the grant at a different,
  unverified process. Now `handle_one_connection` opens the client **once** via
  the new RAII `OwnedProcessHandle::open_client` (with
  `PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_DUP_HANDLE`) and threads that
  single handle through `check_client_identity` → `handle_pipe_request_inner` →
  `duplicate_volume_handle_to_client`. The handle verified is the handle the
  grant duplicates into - no second PID→handle resolution exists.
- **`broker/process_handle.rs`** (new submodule via `#[path]`) holds the
  trust-boundary machinery: `OwnedProcessHandle` (RAII; `Drop` closes on every
  path), `query_process_image_name` (one shared image-name read),
  `is_acmex_daemon_image` (the pure name allow-list predicate), and
  `verify_client_handle`. The split also keeps `broker.rs` under the 800-LOC
  ceiling (721 LOC).
- **Lossless image-name decode (folds in WI-4.2 intent):** the unified
  `query_process_image_name` returns `OsString` via `OsString::from_wide`, and
  `is_acmex_daemon_image` matches on `&OsStr`, so the daemon-identity decision is
  never made on a `from_utf16_lossy`-mangled path. This also removed the broker
  `from_utf16_lossy` site from the anti-pattern gate.
- **Tests:** `is_acmex_daemon_image` has cross-platform unit tests (accepts the
  daemon-name forms incl. versioned prefixes; rejects other images and a path
  whose *directory* - not file name - contains `acmexd`). They compile into the
  Windows test binary (`cargo xwin test --no-run` confirms discovery); the
  broker is a Windows-only `[[bin]]`, so they run on the Windows CI test job.
  The single-handle invariant is additionally enforced at compile time:
  `duplicate_volume_handle_to_client` takes `&OwnedProcessHandle`, so it
  **cannot** be called with a bare PID.
- **Verify:** native + `cargo xwin` (Windows) `--all-targets -D warnings` clippy
  clean; file-size + anti-pattern gates green for broker.

---

### WI-8.2 - Document the daemon-nonce security property (Category 8)

**Goal:** make explicit that the FNV-1a handshake nonce is **not** a cryptographic
authenticator - its security derives entirely from the `0700` runtime dir
(WI-2.2) that hides it from other users.

**Files:** doc comment on the nonce/handshake code + a short section in this guide
/ the audit.

**Steps:**

1. Add a doc comment at the handshake site stating: the nonce provides liveness /
   accidental-cross-talk protection, **not** authentication; confidentiality of
   the nonce rests on the runtime-dir perms; if the threat model later requires
   authenticating the peer, replace FNV-1a with an HMAC over a shared secret.
2. Cross-reference WI-2.2 (dir perms) as the control this property depends on.

**Acceptance criteria:** the security property is documented at the code site and
linked to WI-2.2; no code behaviour change.

**Verify:** `cargo doc -p <crate>` builds; reviewer confirms the note.

---

### WI-7.1 - Bug-for-bug parity corpus for pathological names (Category 7)

**Goal:** guarantee ACMEX enumerates the same names Windows does, including
pathological ones (trailing dots/spaces, reserved device names, very long names,
surrogate-bearing names), so behaviour stays compatible.

**Files:** `crates/acmex-mft/tests/` (parity test) and/or the existing parity
harness referenced by `scripts/trial_run.ps1`.

**Steps:**

1. Extend the parity corpus generator (`scripts/windows/create_mft_test_tree.ps1`)
   to create: trailing-dot/space names, `CON`/`NUL`-like names, max-length
   components, and an unpaired-surrogate name (ties to WI-4.1/4.4).
2. Add a parity assertion: ACMEX's enumerated set for the test tree equals the
   reference Windows enumeration (the trial harness already compares - extend its
   corpus and assertions).
3. For names ACMEX intentionally normalises (e.g. lossy until WI-4.4), assert the
   **documented** behaviour explicitly so a future silent change fails the test.

**Acceptance criteria:** parity test includes the pathological corpus and runs in
CI (Windows lane); divergences are either fixed or explicitly asserted as known.

**Verify:** Windows: `scripts/trial_run.ps1` (elevated) + `cargo nextest run -p
acmex-mft -- parity`.

**Implementation notes (landed on `harden/wi-7.1-parity-corpus`):**

- **Not Windows-only after all.** ACMEX reads **offline** `.iocp` MFT captures on
  any platform (`load_iocp_to_index`), so the parity check runs on macOS against
  the pre-captured local corpus - no live elevated Windows volume required.
- **`crates/acmex-mft/src/parity_tests.rs`** (crate-internal `#[cfg(test)]`, so it
  can reach the `pub(crate)` decoder) holds two tiers:
  - **Tier 1 (always-on, CI):** feeds pathological `$FILE_NAME` UTF-16 through
    the WI-4.1 `decode_name_u16` and pins the documented behaviour - trailing
    dot/space, reserved device names (`CON`/`NUL`/…), and 255-char max-length
    components decode **verbatim** (Win32 stripping/remapping is above the FS,
    not in the MFT); valid Unicode is lossless; an unpaired surrogate becomes a
    **counted** U+FFFD (pins WI-4.1 until WI-4.4 lands).
  - **Tier 2 (env-gated):** when `ACMEX_PARITY_DATA_DIR` points at captured
    `.iocp` + `cpp_<drive>.txt` artifacts, loads a drive offline via the
    production `process_record` path and asserts ACMEX enumerates **every**
    file/dir path the C++ reference does. Skips cleanly in vanilla CI (corpus is
    gitignored).
- **Real divergences found and asserted (the test's whole point):** running
  Tier 2 against the live `drive_g` capture surfaced (1) a trailing-`\`
  directory-presentation difference (normalised away on both sides), (2) **ADS**
  - C++ lists `path:stream`, ACMEX tracks streams outside the path namespace
  (filtered + asserted absent from the path set), and (3) **hard links** - ACMEX
  enumerates every link name while C++ lists the inode once (ACMEX path set is a
  legitimate superset; extras asserted well-formed). Result on `drive_g`: 15049
  reference file/dir paths all found, 2 ADS-only, 3 hard-link aliases.
- **Corpus generator** `scripts/windows/create_mft_test_tree.ps1` extended with a
  pathological-names step (trailing dot/space, reserved, max-length) created via
  the `\\?\` extended-length prefix so they land verbatim on disk; surrogate
  names are exercised at the decoder (Win32 string APIs reject them).
- **Verify:** `cargo nextest run -p acmex-mft -- parity` (CI / skip mode) +
  `ACMEX_PARITY_DATA_DIR=<dir> cargo nextest run -p acmex-mft -- parity` (offline,
  validated on the local corpus). Native clippy `--all-targets -D warnings` clean.

---

### WI-3.1 - Path identity helper + scoping invariant (Category 3)

**Goal:** no safety/scoping decision is made by comparing path **strings**; where
identity matters, compare `(device, inode)` (Unix) / file ID (Windows), and the
drive-scoping invariant is documented and tested.

**Files:** `crates/acmex-security/src/fs.rs` (or a small `path_identity` module);
the drive-scoping logic in `acmex-core` query path from audit §3.

**Steps:**

1. Add `pub fn paths_identical(a: &Path, b: &Path) -> io::Result<bool>` that
   compares `std::fs::metadata` `dev`+`ino` on Unix (`MetadataExt`) and the file
   index/volume id on Windows. Document that this answers "same file", not "same
   string".
2. Audit the §3 sites: confirm drive-scoping uses the structured `drive` field /
   normalised comparison, **not** raw `starts_with` on display strings. Where a
   string compare is genuinely correct (e.g. comparing already-normalised drive
   letters), document why with `// AUDIT-OK(path): normalised drive letter`.
3. Add an invariant doc comment on the scoping function: inputs are normalised
   before comparison; case-insensitive only on Windows drive letters.

**Acceptance criteria:** `paths_identical` exists with tests; no scoping decision
relies on un-normalised path-string comparison; remaining string compares are
`AUDIT-OK(path)`-annotated.

**Tests:** `paths_identical_true_for_hardlink` / `_for_symlink_target` (Unix:
create a hardlink and a symlink, assert identity vs. a different file is `false`);
a scoping unit test that a path on drive `D` is never returned by a `C`-scoped
query even if the display strings share a prefix.

**Verify:** `cargo nextest run -p acmex-security -p acmex-core`

---

## 2. Definition of done (whole effort)

The effort is complete when **all** of the following hold:

1. Every WI in §1.1 is ✅ (or 🟨 with a maintainer-approved RFC for WI-4.4), with
   its Commit + Verified columns filled.
2. The §1.2 rollup reads **100%** for categories 1, 2, 3, 5, 6, 7, 8 and the
   guard row G; category 4 reads 100% for "non-silent + measured + argv/IPC
   correct" with WI-4.4 tracked separately as the elimination follow-up.
3. `just go` (or `rust-script scripts/ci/ci-pipeline.rs go -v`) is green.
4. `just audit-gate` (WI-G.1) passes and is wired into the pipeline.
5. `LOG/<YYYY_MM_DD_HH_MM>_CHANGELOG_HEALING.md` records, per WI, what was wrong,
   why, and how it was fixed.
6. No new blanket `#[allow(...)]`; every exception is a scoped
   `#[expect(..., reason = "...")]` or an `// AUDIT-OK(<category>): <reason>`
   marker.

---

## 3. Quick reference - per-category exit checklist

- **§1 TOCTOU:** single-fd `secure_remove`; randomised `create_new` temps. ✔ when
  WI-1.1, 1.2, 2.4 ✅.
- **§2 Perms:** secrets/dirs born at final perms; no chmod-after. ✔ when WI-2.1–4 ✅.
- **§3 Path identity:** `paths_identical` + documented scoping. ✔ when WI-3.1 ✅.
- **§4 Bytes:** one instrumented decoder + counter; `OsString` argv; strict
  decision parses; RFC for lossless storage. ✔ when WI-4.1–3 ✅, 4.4 🟨 approved.
- **§5 Panic=DoS:** lints on+deny; checked/`.get()` parsers; malformed corpus. ✔
  when WI-5.1–3 ✅.
- **§6 Errors:** no silent behaviour-affecting discards. ✔ when WI-6.1–3 ✅.
- **§7 Parity:** pathological-name corpus in CI. ✔ when WI-7.1 ✅.
- **§8 Trust boundary:** single threaded handle; nonce property documented. ✔ when
  WI-8.1–2 ✅.
- **§G Guard:** grep-gate authored, green, **and wired into the pipeline**. ✔ when
  WI-G.1 ✅.

---

## 4. Closeout & validation record (2026-06-04)

The effort is **complete**. All 20 work items landed across PRs **#345–#355**;
WI-4.4 alone remains 🟨 by design (RFC `refactor/lossless-name-column-rfc.md`
landed; *elimination* implementation is a maintainer-gated follow-up - WI-4.1
already ships the required non-silent/measured/tested mitigation).

**Definition-of-done verification (§2):**

| # | Clause | Result |
|---|--------|--------|
| 1 | Every WI ✅ (or 🟨+RFC for 4.4) | ✅ - 19 ✅, WI-4.4 🟨 (permitted) |
| 2 | §1.2 rollup 100% | ✅ - categories 1/2/3/5/6/7/8/G = 100%; cat 4 = 100% for non-silent+argv (4.4 elimination tracked) |
| 3 | `just go` green | ✅ - `just go` PHASE 1 COMPLETE, 151s, all steps green |
| 4 | `audit-gate` passes + wired | ✅ - `just go` ran **6** fanout commands incl. `✅ Anti-pattern gate (2s)` |
| 5 | Per-WI healing logs | ✅ - `LOG/*_CHANGELOG_HEALING.md` (gitignored) |
| 6 | No blanket `#[allow]` | ✅ - all exceptions scoped `#[expect(reason)]` / `// AUDIT-OK` |

**Incident learned during closeout - stale pipeline binary silently dropped the
gate.** The v0.5.111 ship run (`LOG/Output`) executed a *cached* release build
of `acmex-ci-pipeline` that predated the WI-G.1 wiring: it ran only **5** fanout
commands and the "Anti-pattern gate" step never fired, yet the run shipped
green. Root cause: `cargo run --release` reused a stale binary, and the forced
`cargo clean` on toolchain bumps had been wiping/rebuilding `target/` around it.
**Fix (PR #355):** `just go`/`ship`/`phase2` build the pipeline into a
`--target-dir target/ci-bootstrap` sibling that `cargo clean` never touches, so
the binary is fresh every run. Verified: the subsequent `just go` ran **6**
fanout commands with the gate present and passing. *Lesson: adding a pipeline
validation step is not enough - confirm the running binary is rebuilt, or a
stale artifact can silently skip it.*
- **§G Guard:** grep-gate in CI. ✔ when WI-G.1 ✅.

---

## 5. Follow-up record - malformed-name forensics (2026-06-05)

WI-4.4's *elimination* half landed in **#358** (lossless WTF-8 name storage;
surrogate-named files are enumerated + byte-recoverable). This follow-up
(`feat/malformed-name-forensics`) makes that loss-of-hiding **usable and
provable**:

- **Forensic query surface.** New `--malformed` / `--well-formed` /
  `--malformed-path` filters and opt-in `malformed` / `malformed_path` /
  `name_hex` columns. The `malformed` leaf predicate compiles to the hot-path
  `SearchFilters` toggle (keeps the `--limit` fast path), evaluated against the
  **lossless** `CompactRecord::name_bytes`; `malformed_path` is post-filtered
  over the resolved parent chain. `name_hex` is the lowercase hex of the true
  WTF-8 leaf bytes (projection-only; not in the binary shmem record). Opt-in
  only - none are added to `--columns all`, so default output is byte-identical.
- **Two real hiding bugs fixed (not test-only).**
  `tree::resolve_path_cached_with_malformed` judged component emptiness on the
  lossy `&str` (empty for an ill-formed name), so a surrogate-named directory
  **truncated** the resolved path of everything beneath it; now judged on
  `name_bytes`. `numeric_top_n` row materialization skipped records whose lossy
  name was empty (`name.is_empty()`), dropping ill-formed-named records; now
  gated on `rec.name_len == 0` (byte length). Both are WI-4.4 in spirit: a
  crooked name can no longer hide a file or its descendants from search/resolve.
- **Windows proof scripted.** `scripts/windows/create-corrupted-name-tree.rs
  --verify` now also asserts `acmex '*' --malformed` returns **exactly** the
  ill-formed on-disk entries - the WI-4.4 find+open claim plus the new filter,
  checked end-to-end. **Open item:** one elevated run on a real NTFS volume to
  close the live-Windows acceptance.
- **Verification:** whole-workspace clippy `--all-targets` clean (ultra-strict
  lints); 1896 tests pass; native + `cargo xwin` (Windows) clippy clean;
  anti-pattern + file-size gates green.