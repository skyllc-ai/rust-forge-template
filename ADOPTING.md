<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# ADOPTING.md: bringing the scaffolding to an EXISTING project

You have a Rust project with real code and real history, and you want this
template's machinery. That is the third entry point (next to "new project"
and "join a project"), and it works, because the machine decomposes into
layers with very different retrofit costs. Only one layer is expensive, and
it has a ratchet.

**The one rule:** everything happens on a branch, nothing is enforced until
you flip it on, and the adopt script never overwrites a file you already
have.

## The cost map

| Layer | Retrofit cost | Touches your code? |
| --- | --- | --- |
| Delivery machinery: `just` pipeline, gate manifest + generated hooks, CI workflows, release lanes | Low | No |
| Hygiene: `cargo fmt`, typos, taplo, license headers, file-size | Low to medium | Mechanical one-shot commits |
| Supply chain: cargo-deny, cargo-vet | Low | No. Exemptions grandfather your existing tree; debt is visible and burns down at your pace |
| Test runner: nextest profiles, weekly deep checks | Low | No |
| The ~200-lint posture | High, scales with your LOC | Yes. This is the entire cost, and it is optional and staged |

## Step 1: run the adopt script (on a branch, automatically)

From the root of YOUR repository, with a clean working tree:

```bash
curl -fsSL https://raw.githubusercontent.com/skyllc-ai/rust-forge-template/main/adopt.sh | bash
```

What it does, and what it refuses to do:

- creates a branch `adopt/rust-forge-scaffolding` in your repo
- copies the machinery-only subset in: `just/` + `justfile`, the gate
  manifest and its generator crates, the pipeline crate, git hooks, CI
  workflows, nextest profiles, deny/vet/typos/taplo/clippy/rustfmt configs,
  the version-banner crate, `AGENTS.md`, and the policy docs
- renames the internal `acmex` placeholder to your project slug (it asks)
- **never overwrites anything you already have**: where a file exists
  (your `.gitignore`, your workflows, your `deny.toml`, ...), the
  template's version lands next to it as `<name>.forge-suggested` for a
  manual merge, and the script lists every such file at the end
- does NOT touch your `Cargo.toml`, your crates, or your lint levels.
  Instead it writes `forge-adopt-snippets.md` containing the exact TOML
  blocks to paste, with the lints set to **allow** (installed, inert)

It ends by printing your personal to-do list. Nothing is enforced yet.

## Step 2: wire the workspace (paste two blocks)

From `forge-adopt-snippets.md`:

1. Add the tool crates to your `[workspace] members`.
2. Paste the `[workspace.lints]` block, delivered at **allow** levels
   (installed, inert), and add `[lints] workspace = true` per crate.
   Nothing fails, nothing changes, until you ratchet. (Why not warn?
   The gates run clippy with `-D warnings`, which would promote every
   warning to a day-one failure on a legacy codebase.)

Then wire the hooks and prove the machinery runs:

```bash
just setup            # installs the gate tools, wires the hooks
just go               # the pipeline runs end to end on YOUR code
```

## Step 3: the cheap wins (one mechanical PR each)

```bash
cargo fmt --all                      # one big boring commit
reuse annotate ...                   # license headers (see just legal-setup)
cargo vet init && cargo vet          # supply chain live, existing tree grandfathered
```

After this, every NEW dependency and every NEW file is held to the
standard. Your existing code is untouched and unblocked.

## Step 4: the lint ratchet (the road, if you choose it)

Cargo gives you three dials; use them in this order:

1. **Scope dial:** `[lints] workspace = true` is per crate. Pick your
   smallest or newest crate, flip it to the workspace posture, clean it,
   merge. The strictness frontier advances crate by crate; every merge
   stays green.
2. **Level dial:** survey a group ad hoc, outside the gates
   (`cargo clippy --workspace -- -W clippy::correctness`), fix what it
   shows, then flip that group from `allow` to `deny` in the workspace
   block. Waves: correctness first (cheap, highest value),
   then suspicious, perf, pedantic, style, restriction last.
3. **Debt dial:** inside a strict crate, stragglers get file-level
   `#![expect(lint_name, reason = "adoption debt, tracked in #N")]`.
   Expects warn when they become unnecessary, so `grep -rc expect` is a
   live debt metric that only goes down.

Accelerators: `cargo clippy --fix` auto-fixes a large fraction of style
lints, and an AI assistant pointed at `AGENTS.md` is genuinely good at
grinding the residue (the gates verify its work).

## Honest calibration, both directions

The template's donor project did this retroactively to three of its own
tool crates: 270+ violations, resolved in one focused effort with the
patterns above. The same project also measured ~1,766 sites for one lint
(`arithmetic_side_effects`) and consciously declined to adopt it,
documenting why. Both outcomes are the posture working: ratchet what pays,
decline what does not, in writing. Nobody rewrites a codebase wholesale.

## Caveats before you start

- **Toolchain:** the template pins a nightly (for unstable rustfmt
  options). If your project needs stable or an MSRV, use the stable
  downgrade in the README appendix BEFORE the fmt one-shot.
- **Existing CI and hooks:** the script never deletes yours. Expect a
  manual-merge session for workflows if you already have them; the
  `.forge-suggested` files are your diff targets.
- **Layout:** the machinery assumes a Cargo workspace. A single-crate repo
  should first become a one-member workspace (10 minutes, mechanical).
- **Effort scales with LOC.** Step 1-3 are days. Step 4 is a campaign you
  schedule, or skip: the hygiene + supply-chain layers plus enforcement
  on everything new is already a massive upgrade over nothing.
