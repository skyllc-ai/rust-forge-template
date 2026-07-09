<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# rust-forge-template

A **living template** for new Rust projects: a real, buildable, CI-green Cargo
workspace under the placeholder identity `acmex`, carrying a complete quality
machine from day one. Create a copy, run the init ceremony, and start working
inside a fully armed pipeline instead of assembling one.

Extracted from a production Rust workspace; the design rationale lives in the
donor's `docs/research/project-template-extraction.md`.

## Is this template for you?

Thirty seconds of honesty before you invest an hour.

**Skip it — use `cargo new` instead** — if you are:

- working through a tutorial, book chapter, or exercise (Rustlings, Advent of
  Code, katas): the strict lints will fight you while you are still fighting
  the borrow checker, and that fight teaches nothing
- writing a throwaway script, a one-evening experiment, or a quick prototype
  whose whole point is speed over rigor
- allergic to process: this repo rejects commits, rejects pushes, and argues
  back — by design

**Use it if you are starting something meant to live** — a tool, service, or
library that others (including future-you) will depend on:

- you want **excellent Rust posture forced, not aspired to**: ~200 deny-level
  lints (no `unwrap`, no `panic!`, no `todo!`, everything documented, every
  exception carries a written reason), so quality is machine-enforced from
  commit one instead of debated in review
- you want the **delivery machine pre-built**: commit/push gates in seconds,
  PR CI, weekly deep checks (miri, mutation testing), supply-chain vetting,
  license compliance, and release/publishing lanes that already exist and
  switch on with a variable when you are ready
- you know **strictness is only affordable on day one**: the donor project
  measured what retrofitting costs — a single lint had ~1,766 violations by
  the time it was considered, and 341 supply-chain exemptions had to be
  grandfathered; starting strict costs nothing
- you code **with an AI assistant** and want guardrails that make generated
  code prove itself: the gates hold everything (and everyone) to the same
  standard, and bypassing them is mechanically blocked

### What it demands (know before you invest)

| Resource | What you need |
| --- | --- |
| **Machine** | 8 GB RAM minimum (16 GB comfortable once the project grows — fat-LTO release builds are hungry); a few CPU cores (gates run parallel); SSD strongly recommended |
| **Disk** | ~2 GB pinned toolchain + ~1 GB gate tools + 1-2 GB build dir for the skeleton, growing with your code — plan for **10 GB+** per project over time |
| **Network** | First setup downloads roughly 3-4 GB (toolchain, tools, crate index) |
| **Accounts & keys** | A GitHub account, `gh` CLI authenticated, and a **commit-signing key (SSH or GPG)** — the pre-push gate requires every commit signed, and it is a hard gate: no key, no push |
| **Time** | ~30-45 minutes from empty machine to first green `just go` (mostly downloads/compiles); afterwards 2-15 s per commit, 20-60 s per push (warm) |
| **Platform** | macOS and Linux are first-class; Windows works with Git-Bash for the hooks |

### The commitment

Once you are in, **the machine does not allow shortcuts — for you or for
your AI assistant**. Hooks reject bad commits, the push gate rejects
unsigned or failing work, CI re-checks everything, and the bypass
(`--no-verify`) is mechanically blocked for AI sessions and treated as an
incident for humans. That is the deal: you give up the ability to cut
corners, and in return every green build actually means something — the
discipline you would need to impose on yourself (and on generated code) is
enforced by the repo instead.

**The price, stated plainly:** a pinned nightly toolchain (10-minute stable
downgrade documented), ~10 dev tools installed by `just setup`, a few seconds
per commit and under a minute per push for the gates, and lints that WILL
reject code that would compile fine. That price is the product.

Rule of thumb: **if the project deserves a README, tests, and a version
number, it deserves this template. If it is a sketch, `cargo new` is the
right tool** — come back when the sketch becomes a plan.

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

**Guided (recommended)** — one script drives the whole journey with a
consent prompt at every step: docs gate → tools → GitHub auth → create/clone
the repo → init ceremony → gate tools + hooks → commit signing → first green
validation run:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/rust-forge-template/main/bootstrap.sh | bash
```

For unattended machines (fleet/CI) there is a separate `--yes` lane that
never generates signing keys — see GETTING-STARTED's
"Unattended / fleet provisioning" section.

**Manual** — the same journey as individual commands, for people who want
to see every move (this is also exactly what the script runs):

```bash
# 1. Create your repo from this template (fresh history, no coupling)
gh repo create my-org/myproj --template <owner>/rust-forge-template --private --clone
cd myproj

# 2. Init ceremony (renames acmex → your identity, resets earned state)
just init myproj my-org "My Org LLC" "Me <me@example.com>"

# 3. Gate tools + hooks, commit signing, then prove the machine
just setup
just setup-signing
just go

# 4. GitHub-side state a template cannot carry
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

Dual-licensed **MIT OR Apache-2.0** (the Rust-ecosystem default), so projects
of any license can adopt the scaffolding. Keep the dual license or pass
`license=<SPDX-id>` to `just init`: the ceremony rewrites every SPDX header,
`Cargo.toml`, `REUSE.toml`, and the `LICENSE` pointer, then the `reuse` gate
holds the build red until you drop the matching text into `LICENSES/` —
the machine itself enforces a complete relicense.
