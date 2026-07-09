<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# rust-forge-template

A **living template** for new Rust projects: a real, buildable, CI-green Cargo
workspace under the placeholder identity `acmex`, carrying a complete quality
machine from day one. Create a copy, run the init ceremony, and start working
inside a fully armed pipeline instead of assembling one.

Extracted from a production Rust workspace; the design rationale lives in the
donor's `docs/research/project-template-extraction.md`.

## What you get on day one

| Layer | Contents |
| --- | --- |
| **Lint posture** | ~200-lint deny-everything `[workspace.lints]` (no `unwrap`/`panic`/`todo`, everything documented, `#[expect]` with reason instead of `allow`), nightly rustfmt, clippy.toml test relaxations |
| **Local gates** | `gates.toml` manifest → generated pre-commit / pre-push hooks (fmt, typos, REUSE, taplo, file-size, commit conventions, signatures, clippy tiers, tests, vet, deny, machete) with drift detection |
| **Pipeline** | `just go` (validation lane) and `just ship` (resumable bump → changelog → signed release PR → auto-merge) driven by the `acmex-ci-pipeline` crate |
| **CI** | `pr-fast.yml` tier-1 required gate (validated against gates.toml by `acmex-gen-workflow`), weekly tier-2 (miri, careful, mutants, udeps, hack, coverage), CodeQL, commitlint, nightly canary, dependabot triage + auto-merge, CI-failure notify + auto-rerun |
| **Supply chain** | cargo-vet (5 community audit-set imports, zero exemption debt), cargo-deny, SHA-pinned actions, committed `Cargo.lock` |
| **Licensing** | REUSE/SPDX compliance (checked at commit time), per-file headers, LICENSES/ store |
| **Release lanes (dormant)** | Multi-target release build, crates.io publish (release-plz), winget, SLSA attestation — all present, all inert until you flip a repo variable (see `COMPONENTS.md`) |
| **Skeleton** | `acmex-core` (lib), `acmex-cli` (bin `acmex`), `acmex-version` (shared `--version` machinery) — hello-world code that exercises every gate honestly |

## Quickstart

> New to Rust, `just`, or any of this? **[GETTING-STARTED.md](GETTING-STARTED.md)**
> is the zero-knowledge runbook — from empty machine to green pipeline,
> including the daily loop and a fix-it table for every gate.

```bash
# 1. Create your repo from this template (fresh history, no coupling)
gh repo create my-org/myproj --template <owner>/rust-forge-template --private --clone
cd myproj

# 2. Run the init ceremony (renames acmex → your identity, resets earned state)
just init name=myproj org=my-org entity="My Org LLC" author="Me <me@example.com>"

# 3. Install every gate tool + wire the hooks (idempotent), then prove the machine
just setup
just go

# 4. Create the GitHub-side state a template cannot carry
#    (rulesets + merge queue, required checks, labels, lane variables)
bash scripts/ci/bootstrap-github.sh
```

After init, `rg -i acmex` returns nothing — that emptiness is the proof the
rename ceremony completed.

## Growing the project

The machinery ships at 100% and idles; the product grows through recipes.
`COMPONENTS.md` is the master catalog for both:

- **Lanes** (machinery you switch ON): crates.io publishing, winget, codecov,
  SLSA, the release pipeline. Dormant behind repo variables (`LANE_*`) and
  `release-plz.toml` flags — activation is a data change, never a new file.
- **Components** (structure you ADD): new crates, fuzz targets, benches.
  Each entry documents prerequisites, tooling, files touched, and a verify
  command that always ends in `just go`.

## Daily driving

```bash
just go            # full validation lane (no version bump, no push)
just check         # quick compile + lint sweep
just fmt           # rustfmt
just test          # nextest with coverage instrumentation
just lint-prod     # strict production clippy
just ship          # validate → bump → changelog → release PR (resumable)
```

## Toolchain policy

The workspace pins a **nightly** toolchain (`rust-toolchain.toml`) because the
rustfmt configuration uses unstable options. `just toolchain-ensure` installs
the pin; `just toolchain-sync` walks the pin forward safely; the nightly-canary
workflow builds against the floating nightly weekly as an early-warning system.

### Appendix: stable downgrade (10 minutes)

Projects that prefer stable:

1. `rust-toolchain.toml`: set `channel = "stable"`, drop `miri` from components.
2. `rustfmt.toml`: delete `unstable_features` and every option marked
   nightly-only (`imports_granularity`, `group_imports`, `wrap_comments`,
   `format_code_in_doc_comments`, `normalize_*`, `format_macro_*`,
   `overflow_delimited_expr`, `hex_literal_case`).
3. Root `Cargo.toml`: add `rust-version = "<current stable>"` to
   `[workspace.package]`; add `msrv = "<same>"` to `clippy.toml`.
4. `tier-2.yml`: remove the miri job.
5. `just go` to confirm.

## Keeping up with the template

Derived projects can pull scaffolding improvements without merging histories:

```bash
git remote add template https://github.com/<owner>/rust-forge-template
git fetch template
git diff template/main -- justfile just/ scripts/ .github/ Cargo.toml
```

Cherry-pick what you want; `TEMPLATE_VERSION` records the baseline you started
from. Improvements you make to the machinery inside a product repo should land
in the template first (its own CI proves them), then flow down.

## License

Template scaffolding: MPL-2.0 placeholder — the init ceremony rewrites the
license identity (`LICENSE`, `LICENSES/`, `REUSE.toml`, SPDX headers) to your
project's choice.
