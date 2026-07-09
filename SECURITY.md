# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | ✅        |
| < latest | ❌       |

Only the latest release receives security updates. We recommend always running
the most recent version.

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

If you discover a security vulnerability in ACMEX, please report it responsibly
through one of these channels:

1. **GitHub Security Advisories (preferred)**
   → [Report a vulnerability](https://github.com/acmex-org/acmex/security/advisories/new)

2. **Email**
   → [`security@acmex.example`](mailto:security@acmex.example)

### What to include

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- Affected versions (if known)
- Any suggested fix or mitigation

### What to expect

| Step | Timeline |
|------|----------|
| Acknowledgement | Within **48 hours** |
| Initial assessment | Within **7 days** |
| Fix + advisory published | Within **30 days** (critical) / **90 days** (other) |

We will credit reporters in the advisory unless anonymity is requested.

## Scope

This policy covers:

- The `acmex` binary
- All workspace crates (`crates/acmex-cli`, `crates/acmex-core`,
  `crates/acmex-version`) and the internal CI tool crates under `scripts/`
- Build and CI infrastructure (GitHub Actions workflows, git hooks,
  release pipeline)

### Out of scope

- Third-party dependencies (report upstream; we monitor via `cargo deny` and
  Dependabot)

## Security Measures

This project maintains the following security practices.

### Code

- **Signed commits** — All commits are cryptographically signed (GPG/Ed25519)
- **Strict Clippy** — `unsafe_code = "deny"`, `unwrap_used = "deny"`,
  `expect_used = "deny"` enforced workspace-wide
- **No unsafe code** — Zero `unsafe` blocks in production code without
  explicit `#[allow(unsafe_code)]` and safety documentation
- **SPDX compliance** — Every source file carries
  `SPDX-License-Identifier: MPL-2.0`

### Dependencies

- **Dependency auditing** — `cargo deny check` runs on every PR
  (advisories, licenses, bans, sources)
- **Audit trail** — `cargo vet check --locked` runs on every PR.
  Every resolved crate-version must be covered by an imported audit
  (Mozilla, Google, Bytecode Alliance, ISRG, Zcash), a local audit
  in `supply-chain/audits.toml`, or a grandfathered exemption in
  `supply-chain/config.toml`.  The
  `.github/workflows/cargo-vet-refresh.yml` workflow refreshes
  upstream imports weekly via PR.
- **Structural audit** — `just geiger` produces an on-demand
  `unsafe` / `build.rs` / proc-macro footprint report for the
  resolved dep tree (run monthly; compare against baseline).
- **Dep-tree growth annotation** — every Dependabot PR is
  automatically annotated if `Cargo.lock` grows by more than a small
  threshold, surfacing unexpected transitive fan-out for human review.
- **Software Bill of Materials (SBOM)** — every release ships a
  CycloneDX 1.5 JSON SBOM per workspace crate
  (`sbom-<crate>.cdx.json`), covered by the same SLSA
  build-provenance attestation as the binaries.  Inspect with any
  CycloneDX-aware tool:
  ```bash
  jq '.components[] | {name, version, purl}' sbom-acmex-cli.cdx.json
  ```
- **Semantic SAST** — `.github/workflows/codeql.yml` runs CodeQL's
  Rust query pack on every PR plus a weekly baseline.  Rust is in
  CodeQL's public preview (since CodeQL 2.22.1, July 2025); findings
  are informational until we have a few weeks of clean baselines.
- **Automated dependency updates** — Dependabot monitors Cargo and GitHub
  Actions dependencies.  **Patch-level bumps** are eligible for
  auto-merge via `.github/workflows/dependabot-auto-merge.yml` — but
  only if ALL required checks are green (`cargo-deny`, `cargo vet
  check --locked`, clippy, tests, doc-tests, file-size policy) and
  there is no active security advisory.  **Minor and major bumps**
  continue to require human review and manual merge.  Auto-merge
  never bypasses `main`'s branch protection rules (signed commits,
  required reviews, required checks) — it just queues the merge for
  when those conditions are met.

### CI / release pipeline

- **CI action pinning** — All GitHub Actions are pinned to immutable commit
  SHAs to prevent supply chain attacks
- **Least-privilege CI** — Workflows use `permissions: contents: read`
  by default; `write` scopes are explicit and scoped to the minimum
  job that needs them.
- **Concurrency hygiene** — Every workflow declares a `concurrency:`
  group.  Superseded PR runs cancel cleanly; release and scheduled
  runs queue instead of being cancelled mid-flight (important so a
  half-signed release asset never ships).
- **Windows regression check** — the PR-blocking `windows-lint` job
  runs `cargo clippy -- -D warnings` natively on `windows-latest` so
  Windows-only breakage surfaces before the release pipeline
  discovers it.
- **Branch protection** — `main` requires signed commits + passing
  Tier 1 checks (Clippy, tests, doc tests, security, build, file-size
  policy) before merge.
- **Tag protection** — the `tag-protection-v-prefix` ruleset blocks
  deletion / force-update of any `v*` tag (release integrity).
- **SLSA build-provenance** — every release asset (binaries, ZIP
  bundles, CHECKSUMS.txt, and SBOM JSON files) is signed via
  Sigstore OIDC by `actions/attest-build-provenance`.  Verify:
  ```bash
  gh attestation verify <file> --owner acmex-org
  ```
- **Commit-ancestry guard** — `release.yml` rejects any
  `workflow_dispatch` whose `commit_sha` isn't an ancestor of `main`,
  blocking rollback attacks.
- **SHA256 checksums** — `CHECKSUMS.txt` accompanies every release;
  the checksums file is itself covered by the SLSA attestation.
- **Per-workflow failure triage** — CI failures open issues with
  distinct labels (`ci-failure-tier-1`, `ci-failure-tier-2`,
  `ci-failure-release`) so a release failure is never buried as a
  comment on an older Tier 2 flake issue.
