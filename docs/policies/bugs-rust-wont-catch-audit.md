<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) 2025-2026 Acmex Placeholder LLC.
-->

# "Bugs Rust Won't Catch" — Donor-Project Codebase Audit (worked example)

> **Provenance note — read this first.** This document is an
> **inherited donor-project artifact**, kept in the template as a
> worked example of how to run a boundary-bug audit against a real
> codebase.  Every file path, crate name, line number, and finding
> below refers to the **donor project** (a Windows NTFS file-search
> tool with a daemon, a privileged broker, and an on-disk encrypted
> cache) — none of that code exists in this template.  What transfers
> is the **method** (the eight article categories, the threat-model-
> first severity calls, the pattern sweeps in Appendix A) and the
> **remediation playbook** in [`bugs-rust-wont-catch-implementation.md`](bugs-rust-wont-catch-implementation.md).
> Re-run this audit against your own code once it has boundaries worth
> auditing; replace this document with your findings.

**Audit date:** 2026-06-04 (donor project)
**Reference article:** *Bugs Rust Won't Catch* — Matthias Endler / corrode.dev
(<https://corrode.dev/blog/bugs-rust-wont-catch/>), derived from the April 2026
Canonical/uutils audit (44 CVEs).

## Purpose & scope

The article catalogues the classes of bug that survive Rust's borrow checker,
Clippy, and `cargo audit` because they live at the **boundary between the
program and the messy outside world** — paths, bytes, syscalls, and trust
boundaries. This document maps each of those categories onto the donor's source
tree, points at concrete code, explains *why* each site is (or could become) a
problem **given the donor's actual threat model**, and recommends fixes.

This is an analysis document, not a set of applied changes. Nothing in the code
was modified.

### Donor threat model (so severities are honest)

The donor tool is not `cp`/`rm` running as root, so most findings are **lower
severity** than the uutils CVEs. Its relevant exposure surface was:

1. **A long-running daemon** (`acmex-daemon`) that parses cache files and serves
   IPC requests. The release profile sets `panic = "abort"` (Cargo.toml:645), so
   **any panic in any worker tears down the whole daemon for every client** — a
   panic is a clean denial-of-service.
2. **A privileged Windows broker** (`acmex-broker`) that runs as a Service, holds
   `SeBackupPrivilege`, opens raw volume handles, and `DuplicateHandle`s them
   into client processes after an identity check. This *is* a privilege/trust
   boundary.
3. **On-disk secrets:** `acmex-security::keystore` stores the AES-256 cache key
   (`key.bin` on Unix, DPAPI blob on Windows). The cache itself
   (`*_compact.acmex`) is an encrypted index of every filename on every volume —
   sensitive metadata.
4. **Untrusted-ish inputs:** raw MFT bytes (local, admin-read, semi-trusted) and
   cache/cursor files on disk (tamperable by anything with write access to the
   cache dir).

The biggest *correctness* issue (not security) is that the tool's **core job —
finding files by name — silently corrupts a class of real filenames**
(see §4).

## Summary table

| # | Article category | ACMEX status | Worst concrete site | Sev* |
|---|------------------|-------------|---------------------|------|
| 1 | TOCTOU across two syscalls | **Present** | `secure_remove` metadata→open; predictable `.tmp` `File::create` | Med |
| 2 | Permissions set *after* creation | **Present (systemic)** | `key.bin` write→chmod; `create_secure_dir`; `atomic_write` | **High** |
| 3 | String equality on paths ≠ FS identity | Minor | drive-letter / `path_contains` scoping; no `canonicalize` | Low |
| 4 | UTF-8 conversion at byte boundaries | **Present (core correctness)** | `String::from_utf16_lossy` on every NTFS name | **High** |
| 5 | `panic!` as DoS | **Mitigated but gapped** | parser indexing on raw bytes + `panic="abort"` daemon; no `arithmetic_side_effects` | Med |
| 6 | Discarded errors | Mostly OK | broadly `drop(..)`/`let _ =` on cleanup; a few meaningful | Low |
| 7 | Bug-for-bug compatibility | N/A-ish | ACMEX is not a reimplementation; parity vs Windows search semantics | Low |
| 8 | Resolve before crossing a trust boundary | Watch | broker PID→identity verification; non-crypto auth | Med |

*Severity is relative to ACMEX's threat model, not absolute.

---

## 1. TOCTOU — don't trust a path across two syscalls

> *Article rule: anchor on a file descriptor, not a path; if you act on the same
> path twice, assume it's a TOCTOU bug.*

ACMEX's high-level file ops all take `&Path` and re-resolve on each call. ACMEX is
not privileged the way `install`/`cp` are, but the cache directory is a
shared-ish location and the broker is privileged, so the pattern still matters.

### 1.1 `secure_remove` — `metadata()` then `open()` (check → use)

`crates/acmex-security/src/fs.rs:250-288`

```rust
let meta = std::fs::metadata(path)?;        // (1) follows symlinks; checks len
// ...
let mut file = std::fs::OpenOptions::new().write(true).open(path)?; // (2) re-resolves
```

- The length used to drive the zero-overwrite loop comes from syscall (1); the
  bytes are written through syscall (2) which **re-resolves the name**. Between
  the two, the path component can be swapped for a symlink, so the zero-wipe can
  land on a different file than the one whose size was measured. `metadata` also
  *follows symlinks*, so the "file" being wiped may never have been the intended
  target at all.
- Severity Med: `secure_remove` exists specifically to destroy sensitive data
  (the threat actor it defends against is exactly someone with local access).
- **Fix:** open once with `OpenOptions` (anchored fd), then `file.metadata()` for
  the length and write through the *same* handle. Use `symlink_metadata` if you
  must stat by path so a symlink isn't silently followed.

### 1.2 Predictable `.tmp` + `File::create` (symlink-follow / truncate)

- `crates/acmex-security/src/fs.rs:212-226` (`atomic_write`):
  `let tmp_path = path.with_extension("acmex.tmp"); File::create(&tmp_path)?;`
- `crates/acmex-daemon/src/index/search.rs:686-689` (`--out` export): same
  predictable `target.with_extension("acmex.tmp")` + `File::create`.

`File::create` **follows symlinks and truncates**. The temp name is fully
predictable. Anyone able to write in the destination directory can pre-plant the
`.tmp` path as a symlink to an arbitrary file; the privileged/long-running writer
then truncates and overwrites the attacker's target with cache/export bytes
(article CVE-2026-35355 is this exact shape). For `atomic_write` the written
bytes are the *encrypted* cache, so it's data-destruction rather than
disclosure; for `--out` export it is plaintext search results to an
attacker-chosen file.

- **Fix:** `OpenOptions::new().write(true).create_new(true).mode(0o600).open()`
  on a *randomised* temp name in the same directory, then `rename`. `create_new`
  refuses to follow a dangling/existing symlink (article's recommended remedy).

### 1.3 Cache purge does it right (positive example)

`crates/acmex-core/src/compact_cache.rs:235-246` uses `symlink_metadata` (does not
follow the link) and deliberately refuses `remove_dir_all`, only `remove_dir` on
a known-empty dir. This is the defensive shape the article advocates and is worth
keeping as the in-tree reference pattern.

---

## 2. Set permissions at creation, not after  ← highest-value finding

> *Article rule: a file/dir is briefly world-accessible between create and chmod;
> an fd opened in that window keeps access forever. Use `OpenOptions::mode()` /
> `DirBuilderExt::mode()`.*

ACMEX has this anti-pattern **systemically** in the very crate whose job is secure
storage, and it touches the crown-jewel key material.

### 2.1 Cache encryption key written then chmod'd (Unix)

`crates/acmex-security/src/keystore.rs:404-405`

```rust
std::fs::write(&key_path, key)?;                       // raw 32-byte AES key, umask perms
crate::fs::set_file_permissions_owner_only(&key_path)?; // chmod 0600 AFTER
```

- `key.bin` is the **plaintext AES-256 key** that decrypts the entire cache
  (every filename on every volume). It is created with default-umask permissions
  (commonly `0644`/`0664`) and only narrowed to `0600` afterward. Any local user
  who `open()`s it in that window keeps a readable fd even after the chmod.
- `std::fs::write` also creates/truncates by path and follows symlinks (ties to
  §1.2) — a pre-planted `key.bin` symlink redirects the key write.
- The Windows path (`dpapi_write_key`, keystore.rs:192-193) has the same
  write-then-chmod shape, but the blob is DPAPI-encrypted, so lower severity.
- Severity **High** (Unix): direct exposure window on the master key.
- **Fix:** create with `OpenOptions::new().write(true).create_new(true)
  .mode(0o600).open()` (Unix) so the key is *born* `0600`; never write the key by
  bare path.

### 2.2 `create_secure_dir` — `create_dir_all` then `set_permissions`

`crates/acmex-security/src/fs.rs:36-43`

```rust
std::fs::create_dir_all(path)?;                                  // default perms
std::fs::set_permissions(path, Permissions::from_mode(0o700))?;  // narrow AFTER
```

This is the article's textbook example verbatim. The cache/runtime directory
(which holds `key.bin`, the encrypted cache, the IPC socket, and the PID-file
nonce that gates daemon connections) exists with default perms for a window
before being narrowed to `0700`. `create_dir_all` also narrows *only the
leaf* — intermediate components it creates are left at the umask default.

- **Fix:** use `std::os::unix::fs::DirBuilderExt::mode(0o700)` with
  `DirBuilder::recursive(true)` so each created component is born `0700`.

### 2.3 `atomic_write` narrows perms after writing the data

`crates/acmex-security/src/fs.rs:217-223`: `File::create(tmp)` → `write_all(data)`
→ `sync_all` → `set_file_permissions_owner_only(tmp)` → `rename`. The temp file
holds the full payload at default perms for the entire write+sync, then is
narrowed just before the rename. For the encrypted cache this is metadata
exposure of the (encrypted) blob; combined with §1.2 the bigger issue is the
predictable name. **Fix:** create the temp with `.mode(0o600).create_new(true)`.

### 2.4 The codebase already knows the right pattern

`crates/acmex-security/src/runtime_dir.rs:300-303` and `619-622` *do* use
`OpenOptions::new().mode(0o600).create_new(true).open()`. The fix for §2.1–§2.3
is to make `keystore` / `fs::atomic_write` consistent with `runtime_dir`.

---

## 3. String equality on paths ≠ filesystem identity

> *Article rule: resolve paths (`canonicalize`, or compare `(dev, inode)`)
> before deciding two paths are "the same"; never compare path strings for a
> security/safety decision.*

ACMEX is a **read-only** search tool, so there is no destructive `--preserve-root`
analogue. The relevant uses are *scoping* decisions, where string-equality is a
correctness (not safety) concern:

- **Drive scoping:** drive is derived as a `DriveLetter` from a path prefix and
  compared as a value (e.g. `crates/acmex-daemon/src/index/drives.rs:66`,
  `refresh.rs:207` test `to_string_lossy().len() <= 2`). A path reached via a
  symlink or a `subst`/junction to another volume is classified by its *spelled*
  drive letter, not the volume it physically lives on, so it may be filtered into
  the wrong drive's result set.
- **`path_contains` / path filters** are substring matches on the displayed
  path string, not canonical identity. `..`, `.`, mixed separators, 8.3 short
  names, and symlinks/junctions are not normalised, so the same physical file can
  match or miss depending on spelling. Acceptable for a search UX, but document
  it as "string scoping, not identity."
- There is **no use of `std::fs::canonicalize` for identity comparison** anywhere
  in scoping logic (the only `canonicalize` calls — `commands/load.rs`,
  `commands/inspect.rs` — are cosmetic, for display, and even those fall back to
  the raw path with `unwrap_or_else`).

Severity Low (no privileged action keys off these comparisons). If any future
feature keys a *write/delete* off a path comparison, switch to `(dev, inode)` /
canonical identity first.

---

## 4. Stay in bytes at the boundary  ← core-correctness finding

> *Article rule: `from_utf8_lossy` is "fancy data corruption"; strict conversion
> crashes; for Unix-flavoured systems data, use `OsStr`/`Vec<u8>`/`&[u8]`. UTF-8
> is the wrong default for raw OS byte data.*

This is the single most consequential category for ACMEX because **filenames are
the product**, and NTFS filenames are *not* guaranteed valid Unicode.

### 4.1 Every NTFS name is decoded with `String::from_utf16_lossy`

NTFS stores names as UTF-16 code units but **permits unpaired surrogates**
("WTF-16"). ACMEX decodes every name lossily, replacing anything unrepresentable
with U+FFFD, at (non-exhaustive):

- `crates/acmex-mft/src/io/parser/fragment.rs:144`
- `crates/acmex-mft/src/io/parser/index.rs:204,353,452`
- `crates/acmex-mft/src/io/parser/index_extension.rs:133,255,307`
- `crates/acmex-mft/src/io/parser/fragment_extension.rs:98,172`
- the hand-rolled `decode_utf16le_into` in
  `crates/acmex-mft/src/io/parser/unified.rs:23-72` (same U+FFFD semantics,
  just allocation-free)

Consequences — all three are *active* bugs for a search tool:

1. **Unfindable files.** A file whose name contains an unpaired surrogate (legal
   on NTFS, also producible by some apps/malware) is indexed as a string
   containing U+FFFD. A user searching for the real name will never match it.
2. **Silent collisions.** Two distinct names that differ only in
   unrepresentable code units both collapse to identical U+FFFD-bearing strings,
   so counts, dedup, and "go to file" become ambiguous.
3. **Broken round-trips.** A path emitted by ACMEX (display, `--out`, MCP/JSON,
   "reveal in explorer") that contains U+FFFD **cannot be passed back to the OS**
   to open the real file — the bytes no longer name anything.

The root cause is architectural: the name column is a **Polars UTF-8 `String`
column** (see `acmex-polars::columns`, deserialize requires UTF-8 at
`crates/acmex-mft/src/index/storage/deserialize.rs:379`,
`core::str::from_utf8` at `:574`), so the boundary decode is forced into UTF-8.
The article's "pick the right type" rule argues the name should ride as
`OsString`/WTF-8/bytes. On Windows the lossless tool is
`std::os::windows::ffi::OsStringExt::from_wide`, which preserves unpaired
surrogates as WTF-8.

- Severity **High (correctness)**, Low (security). It does not crash; it quietly
  returns wrong answers for a minority of files — which is the worst failure mode
  for a search engine.
- **Realistic fix path:** at minimum, *flag/count* names that required
  replacement (so the corruption is observable, not silent), keep the raw UTF-16
  alongside for exact-open, and document the limitation. A full fix is a
  bytes/WTF-8 name column — a large, deliberate refactor.

### 4.2 `to_string_lossy()` on paths fed to child processes / wire

Dozens of sites convert a `Path` to a `String` lossily before pushing it into a
spawn argv or IPC payload, e.g.:

- `crates/acmex-cli/src/commands/daemon_mgmt.rs:93,97,156` (`--data-dir`,
  `--mft-file` spawn args)
- `crates/acmex-mcp/src/process.rs:19,23,267,270`
- `crates/acmex-client/src/daemon_spawn.rs:333,460`

If `data_local_dir()` or a user-supplied path is non-UTF-8 (possible on Linux;
WTF-8 on Windows), `to_string_lossy` mangles it and the child daemon then operates
on a **different path** than intended (cache written/read at the wrong location,
or a hard failure). These are argv/OsStr boundaries — pass `OsString`
(`Command::arg` takes `AsRef<OsStr>`) instead of round-tripping through `String`.

### 4.3 Lossy decode of subprocess stdout used for control decisions

`from_utf8_lossy` on captured stdout drives logic in several places —
`acmex-broker/src/broker.rs:261`, `acmex-mcp/src/process.rs:500` (parses a PID),
`acmex-client/src/verify.rs:309`. Lossy substitution there can corrupt a parsed
PID/name and lead to a wrong process being trusted/targeted. Prefer strict parse
with explicit error handling on anything that feeds a decision.

---

## 5. Treat every `panic!` as a denial of service

> *Article rule: in code that handles untrusted input, every `unwrap`/`expect`/
> index/`as`/`from_utf8` is a CVE waiting to be filed. Suggested CI baseline:
> `unwrap_used`, `expect_used`, `panic`, `indexing_slicing`,
> `arithmetic_side_effects`.*

ACMEX is **well ahead** of the uutils baseline here — and that deserves credit:

- `Cargo.toml:328-330` denies `unwrap_used`, `expect_used`, `panic`.
- `Cargo.toml:406` denies `indexing_slicing`.
- `Cargo.toml` denies the whole `cast_*` family
  (`cast_possible_truncation`, `cast_possible_wrap`, `cast_sign_loss`,
  `cast_precision_loss`, `cast_lossless`) — covering most of the article's
  "`as` cast" concern.
- `unreachable`, `todo`, `unimplemented`, `panic = "abort"` are all set.

Two real gaps remain:

### 5.1 `arithmetic_side_effects` is NOT enabled, and release has no overflow checks

The one lint from the article's list that is missing. Confirmed absent from
`Cargo.toml`/`clippy.toml`, **and** `overflow-checks = false` for `release`,
`bench`, and `dist` profiles (`Cargo.toml:641,665` and the dist profile). So in
shipped binaries, `+`/`-`/`*` on attacker-influenced integers wrap silently
instead of panicking. The MFT/cache parsers do exactly this kind of arithmetic on
length/offset fields drawn from the input, e.g.
`name_bytes_offset + name_len * 2` at
`crates/acmex-mft/src/io/parser/fragment.rs:138`. Those specific operands are
narrowly bounded today (`file_name_length` is a `u8`, ≤255), so this is *latent*
rather than exploited — but the guardrail the article recommends is off, so a
future widening or a different field can wrap past a `<= data.len()` bounds check
and turn into an out-of-range slice (→ panic, see §5.2).

- **Fix:** enable `arithmetic_side_effects = "warn"` (scoped off in tests), and/or
  use `checked_add`/`checked_mul`/`saturating_*` in the parsers; consider
  `overflow-checks = true` for the `dist` profile.

### 5.2 Manual bounds-checking on raw bytes, with `indexing_slicing` scoped off

The parsers carry file-scoped `#[expect/allow(clippy::indexing_slicing)]`
(`fragment.rs:41,543`, `fragment_extension.rs:36,200,328,378`,
`index.rs:68`, `index_extension.rs:53`, `unified.rs:98`) and then index/slice raw
input directly, e.g. `&data[offset + 20..offset + 22]`
(`fragment.rs:127`) and `&data[name_bytes_offset..name_bytes_offset + name_len*2]`
(`fragment.rs:139`). Correctness now depends entirely on **hand-written bounds
checks** being exactly right. A single off-by-one (or a §5.1 wrap that defeats the
check) produces a slice-out-of-range panic. Because the **daemon parses cache
files** and runs with `panic = "abort"`, one malformed `*_compact.acmex` /
`*_usn.cursor` (tamperable on disk) → panic → the *entire daemon* dies for all
clients. That is a clean local DoS.

- These are the highest-value places to (a) keep `indexing_slicing` *on* and use
  `.get(..)?` / `try_into`, and (b) fuzz with malformed records (`cargo-fuzz`),
  exactly the "run the input through a fuzzer" defense the article gestures at.

### 5.3 Strict `from_utf8` on cache-read paths

`crates/acmex-mft/src/index/storage/deserialize.rs:379` (`String::from_utf8`) and
`:574` (`core::str::from_utf8`) correctly return `Result` (no panic) — good. They
do, however, *reject* a cache whose name bytes aren't UTF-8; since names were
written via `from_utf16_lossy` they always are, so this is consistent with §4
rather than a panic risk. Worth a comment tying the two invariants together.

---

## 6. Propagate errors, don't discard them

> *Article rule: don't lose error information via `.ok()` / `let _ =` /
> `unwrap_or_default`; aggregate the worst exit code; comment any deliberate
> discard.*

ACMEX uses `drop(std::fs::remove_file(..))` / `let _ignore = ..` / `.ok()`
liberally, but the overwhelming majority are **legitimate best-effort cleanup**
(removing stale PID files, sockets, temp files on shutdown) where ignoring the
error is correct — and many already carry an explanatory name (`_ignore`,
`_mkdir_ignore`, `_cleanup`). Examples that are fine:
`acmex-daemon/src/lifecycle.rs:269,286,303-335`, `acmex-mcp/src/process.rs:227-252`,
`acmex-client/src/shmem.rs:402,597,659`.

Points worth a second look:

- **Network writes discarded:** `acmex-client/src/daemon_ctl.rs:197-199,222-224`
  `drop(stream.write_all(..))` / `drop(stream.flush())`. If the control message
  partially writes, the peer may see a truncated frame and the caller proceeds as
  if it succeeded. For a control channel, prefer surfacing the error (or at least
  log it) rather than a bare `drop`.
- **Directory creation ignored before logging:** `log_init.rs:81`
  (`let _mkdir_ignore = create_dir_all(parent_dir)`) and
  `acmex-mft/src/logging.rs:35` — if the dir can't be made, subsequent log writes
  fail silently and diagnostics vanish exactly when they're needed. Low severity,
  but log the failure to stderr once.
- **Exit-code aggregation:** ACMEX is read-only, so the chmod/chown "return the
  last error instead of the worst" CVE has no direct analogue. The daemon's
  per-request handlers should still ensure a failure in one request can't be
  reported to the client as success — spot-check
  `acmex-daemon/src/handler*.rs` result plumbing if/when batch operations are
  added.

No site here rises above Low given the read-only model, but the `daemon_ctl`
write-discards are the ones to fix first.

---

## 7. Bug-for-bug compatibility

> *Article rule: when you reimplement a battle-tested tool, divergence in exit
> codes / option semantics / edge cases is itself a security/safety problem.*

ACMEX is **not** a drop-in reimplementation of an existing binary, so the literal
"shell scripts depend on GNU quirks" risk is mostly N/A. The residual concern is
**semantic parity with the platform's own filename rules**, which the project
already takes seriously:

- Case-insensitive matching is driven by the **live NTFS `$UpCase` table**
  (`acmex-mft/src/platform/upcase.rs`, `acmex-core/src/compact.rs:967-1014`
  compares the cached fold table against the live one), rather than ASCII
  lowercasing — the correct, parity-preserving choice.
- The §4 U+FFFD issue is, framed this way, a *parity* bug: Windows search / the
  shell can find a file that ACMEX cannot, because ACMEX changed the name.
- Recommendation: keep a parity test corpus (the repo already has
  `scripts/verify_parity.rs`, `crates/acmex-diag/parity/`) that includes
  pathological names (unpaired surrogates, trailing dots/spaces, 8.3 aliases,
  reserved device names) and asserts ACMEX matches Windows enumeration.

---

## 8. Resolve inputs before crossing a trust boundary

> *Article rule: once you're across a privilege/namespace boundary, every library
> call may run attacker code; resolve everything you need beforehand.*

The genuine privilege boundary in ACMEX is the **Windows broker**
(`crates/acmex-broker`), a Service holding `SeBackupPrivilege` that opens raw
volume handles and `DuplicateHandle`s them into a client. There is no `chroot`,
and the NSS/`dlopen` issue from the article doesn't apply, but the
**client-identity check is itself a cross-boundary, multi-syscall decision**:

- Flow (`broker.rs:129-167`): get client PID from
  `GetNamedPipeClientProcessId` (`:476-484`) → `verify_client(pid)` whitelist
  (`:495`) → `OpenProcess` + `QueryFullProcessImageNameW` to read the exe path
  (`:279-299`) → `verify_authenticode(path)` (`:244`) → then `DuplicateHandle`
  the privileged volume handle into that PID (`:587-620`).
- **TOCTOU / PID-reuse surface:** the identity (exe path + Authenticode) is bound
  to a *PID*, and the handle is later duplicated to a process opened *again* by
  the same PID. The properties verified at check-time and the process granted the
  handle at use-time are linked only by an integer PID. Windows does not
  aggressively recycle PIDs and the pipe connection pins the peer, so this is
  hard to exploit, but it is the article's "verify across two syscalls" shape and
  deserves a comment proving the PID can't be rebound between check and grant
  (e.g. keep the `OpenProcess(PROCESS_DUP_HANDLE)` handle from the verification
  step and reuse it for the duplicate, rather than re-opening the PID).
- **Authenticode-as-identity:** `verify_authenticode` on the exe path is a
  path-based check (re-resolves the file); pair it with the already-open process
  handle / image section where possible so the *running* image is what's trusted,
  not a path that could differ by the time it's read.

### 8.1 Non-cryptographic "verification" of the daemon (Unix/local)

The daemon↔client handshake relies on a PID file containing a **nonce** plus an
**FNV-1a hash** of the daemon exe path (`acmex-client/src/connect.rs:736`,
`connect_sync.rs:523`, `daemon_ctl.rs:432`, `daemon/src/lifecycle.rs:658-662`).
FNV-1a is a *non-cryptographic* hash: it provides an integrity/version tag, not
authentication. The actual access control is **filesystem permissions on the
runtime dir** that holds the nonce — which loops back to §2.2: if
`create_secure_dir` leaves that directory at default perms during its create→chmod
window, the nonce (the connection capability) is briefly readable by other local
users. Document that the security property is "the runtime dir is `0700` from
birth," and fix §2.2 so that's actually true.

---

## 9. Prioritised recommendations

1. **(High) Birth secrets with correct perms.** Rewrite `keystore` key writes and
   `fs::atomic_write`/`create_secure_dir` to use `OpenOptions::mode()` /
   `DirBuilderExt::mode()` + `create_new(true)` + randomised temp names — mirror
   the existing `runtime_dir.rs` pattern. (§2, §1.2)
2. **(High, correctness) Make name corruption observable, then eliminate it.**
   Count/flag U+FFFD substitutions during parse; preserve raw UTF-16 for exact
   open; plan the bytes/WTF-8 name-column refactor. (§4.1)
3. **(Med) Harden the parsers.** Turn `indexing_slicing` back on in the parser
   modules (or convert to `.get()`/`try_into`), enable
   `arithmetic_side_effects`/`checked_*`, set `overflow-checks = true` for `dist`,
   and add `cargo-fuzz` targets for malformed records/cache files — the daemon's
   `panic = "abort"` turns any parser panic into full-daemon DoS. (§5)
4. **(Med) Anchor file ops on fds.** Fix `secure_remove` to stat-and-write through
   one handle; avoid predictable temp names. (§1.1, §1.2)
5. **(Med) Tighten the broker boundary.** Reuse the verification-time process
   handle for `DuplicateHandle`; comment the PID-rebind argument. (§8)
6. **(Low) Stop round-tripping paths through `String`.** Pass `OsString` to spawn
   argv and IPC; strict-parse subprocess output that feeds decisions. (§4.2, §4.3)
7. **(Low) Surface discarded control-channel write errors.** (§6)

## 10. What Rust *did* buy ACMEX (for balance)

As the article stresses, none of the above are memory-safety bugs. ACMEX parses
raw, attacker-shaped MFT/cache bytes across tens of thousands of lines with
`#![deny(unsafe_code)]` (`Cargo.toml:586`), `zerocopy`-based struct reads, and a
genuinely strict Clippy posture (panic-family + `indexing_slicing` + `cast_*` all
denied) — so the classic C failure modes (buffer overflows, UAF, OOB reads,
uninitialised memory) are absent by construction. The findings here are precisely
the *residual* class the article is about: the boundary between safe Rust and the
messy world of paths, bytes, permissions, and trust.

---

## Appendix A — how this audit was performed

Pattern sweeps across `crates/**/src/**/*.rs` (excluding tests) for: `File::create`
/ `OpenOptions` / `create_new` / `create_dir*`; `remove_file` / `metadata` /
`set_permissions` / `rename` / `canonicalize` / `symlink_metadata`;
`from_utf8_lossy` / `from_utf16_lossy` / `to_string_lossy`; `.ok()` / `let _ =` /
`drop(` around writes; lint config in `Cargo.toml`/`clippy.toml`; and targeted
reads of `acmex-security` (`fs.rs`, `keystore.rs`, `runtime_dir.rs`),
`acmex-mft/io/parser/*`, `acmex-daemon/index/search.rs`, and `acmex-broker/broker.rs`.
Line numbers are accurate as of the audit date and may drift as the tree evolves.

