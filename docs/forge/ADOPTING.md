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

**The one rule:** every FILE change happens on a branch, nothing is
enforced until you flip it on, and the adopt script never overwrites a
file you already have. One honest asterisk: git hooks, signing keys, and
GitHub rulesets are not branch-scoped; they get their own explicitly
sequenced step (step 5), after the branch has merged, so nothing
repo-global changes before the team has agreed to it.

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

- creates a branch `adopt/rust-forge-scaffolding` in your repo (your base
  branch is recorded, for the undo)
- copies the machinery-only subset in: `just/` + `justfile`, the gate
  manifest and its generator crates, the pipeline crate, git hooks, CI
  workflows, nextest profiles, deny/vet/typos/taplo/clippy/rustfmt configs,
  the version-banner crate, `AGENTS.md`, and the policy docs
- renames the internal `acmex` placeholder to your project slug (it asks)
- **never overwrites anything you already have**: where a file exists
  (your `.gitignore`, your workflows, your `deny.toml`, ...), the
  template's version lands next to it as `<name>.forge-suggested` for a
  manual merge, and the script lists every such file at the end. The one
  sanctioned exception: missing artifact entries (`target/`, `build/`,
  `*.forge-suggested`) are APPENDED to your existing `.gitignore`, never
  removing or reordering a line of yours
- **wires your workspace automatically, under a git guard**: workspace
  members, the `[workspace.package]` table (added or completed), the
  dependencies the tool crates need (added if missing; features merged
  into entries you already have), the full lint posture at **allow**
  (installed, inert), plus `license.workspace = true` and
  `[lints] workspace = true` in each of your crates. Every single edit is
  validated with `cargo metadata`; an edit that would break your manifest
  is reverted on the spot and listed in `forge-adopt-fallbacks.txt` for a
  human. `forge-adopt-snippets.md` stays as the record of what was done
  (and the manual recipe for any fallback).
- **commits the whole trial on the adopt branch.** Your base branch is
  untouched; a plain `git commit` is used, so if your own pre-existing
  hooks reject it, that is your policy speaking, never bypassed.

Why "allow" and not "warn" for the lints: the gates run clippy with
`-D warnings`, which would promote every warning to a day-one failure on
a legacy codebase. Allow means installed and silent; the ratchet (step 4)
flips groups to deny when a crate is ready.

## Step 2: try it, keep it, or undo it

```bash
just setup            # installs the gate tools, wires the hooks (repo-local)
just go               # the pipeline runs end to end on YOUR code
just adopt-status     # where the trial stands
```

Like what you see? Push the branch and open a PR; merging it is the
adoption. Not convinced?

```bash
just adopt-undo
```

That returns to your base branch, deletes the adopt branch, and unsets the
repo-local `core.hooksPath`: your repository is restored **bit-for-bit** to
the pre-adoption state. Kept on purpose: installed tools (machine software
you likely want anyway), your SSH key and its GitHub registration
(user-level artifacts), and repo-local signing config if you ran
`just setup-signing` (harmless; the undo output says how to remove it).
Changed your mind again? Re-run `adopt.sh` any time; the trial is cheap in
both directions.

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

## Step 5: the GitHub-side cutover (the part that is NOT branch-scoped)

Everything up to here was files on a branch. Three kinds of Git scaffolding
live OUTSIDE branches and flip once, for the whole repo or the whole clone.
Sequence matters; do these in order, after the adopt branch has merged to
your default branch.

1. **Per-clone git config (each collaborator, each machine).**
   `just install-hooks` sets `core.hooksPath` for that clone; every
   teammate runs it once (it is opt-in by design, and harmless on branches
   that predate the scaffolding: git treats a missing hooks dir as "no
   hooks"). `just setup-signing` configures commit signing for that clone
   (repo-local git config; the key file is the only per-machine artifact).
   Use `just doctor-signing` as the team readiness checklist BEFORE step 3
   makes signatures mandatory.
2. **Harmless server-side state, any time after the merge.** Labels, the
   `LANE_*` variables (all false), and Dependabot config activate nothing
   by themselves; `bootstrap-github.sh` sets them idempotently. The
   merge-method settings (squash-only, auto-merge, delete-branch-on-merge)
   change team workflow, so announce them, but they block nothing.
3. **Rulesets LAST, and only after two preconditions.** The
   `main-protection` ruleset (required `PR Fast CI / required` check +
   merge queue) applies to every PR the moment it exists. Two traps:
   - the required check can only be reported by `pr-fast.yml`, so the
     workflow must already be ON your default branch (i.e. the adopt PR
     merged) or nothing can merge at all;
   - PRs opened BEFORE the adoption do not contain the workflow, so their
     check never reports and they become unmergeable. Update every open
     PR from the default branch (rebase or merge main in) BEFORE creating
     the ruleset, or land them first.
   Add the required-signatures rule only after step 1's doctor checklist
   is green for every committer.

Everything here is reversible (rulesets can be disabled or set to
"evaluate", variables set back to false, `git config --unset
core.hooksPath`), which is what makes the cutover safe to schedule rather
than scary.

## Upgrading later: `adopt.sh --upgrade` (and `just forge-upgrade`)

The template keeps moving (new lints, a newer toolchain pin, gate and
workflow fixes). A repo that was forged or adopted carries its baseline in
`docs/forge/FORGE-STAMP.toml` (`template-version`, `template-commit`), and
the same script that adopts brings it forward, on a branch, without erasing
what you changed:

```bash
just forge-upgrade                # in any forged/adopted repo (clean tree)
# = curl -fsSL .../adopt.sh | bash -s -- --upgrade
just forge-upgrade-status         # branch, base, unresolved suggestions
just go                           # keep it: push the branch, open a PR
just forge-upgrade-undo           # or drop the whole thing
```

What it does, per class of file:

- **machinery files** (`just/`, `scripts/ci`, hooks, workflows, configs,
  policies, `AGENTS.md`, the version crate; for a repo born from the
  template also the `docs/forge/*` guides): a 3-way merge. Base = the
  template at the recorded `template-commit`; when that is unknown (a repo
  forged before the stamp had it) the newest template revision whose
  rendering equals your copy (compared modulo the rename, copyright lines
  and comment reflow), or, for a file you edited, the nearest revision,
  which the report lists as "merged against a nearest baseline: review the
  diff". Untouched files fast-forward, edited files merge, a conflict
  keeps yours and writes the template's version as `<name>.forge-suggested`.
- **the lint posture**: merged key by key. Lints the template added land in
  your `[workspace.lints.*]` tables with their comments; while your posture
  is still at allow (an adoption ratchet in progress) they land at allow.
  A level you changed is kept and reported; a lint the template dropped
  (renamed or removed upstream) is reported, never deleted. `clippy.toml`
  keys the template added are appended.
- **the toolchain pin** follows the template (`--keep-toolchain` keeps yours).
- **generated hooks** are regenerated from the merged `gates.toml`; the
  stamp records the new version and commit.

Never touched: your crates, `supply-chain/`, `CHANGELOG.md`, licenses. The
upgrade is a commit on `forge/upgrade-<version>`; keeping it is a normal PR,
undoing it is deleting the branch. `FORGE_TEMPLATE=/path/to/checkout` (or
`OWNER/REPO`) upgrades from something other than the template's `main`.

## Caveats before you start

- **Toolchain:** the template pins a nightly (for unstable rustfmt
  options). If your project needs stable or an MSRV, use the stable
  downgrade in the README appendix BEFORE the fmt one-shot.
- **Existing CI and hooks:** the script never deletes yours. Expect a
  manual-merge session for workflows if you already have them; the
  `.forge-suggested` files are your diff targets.
- **Layout:** the machinery assumes a Cargo workspace. A single-crate repo
  should first become a one-member workspace (10 minutes, mechanical).
- **Version:** the machinery expects a real `0.1.x` start; a
  `version = "0.0.0"` placeholder is bumped to `0.1.0` by the script and
  the internal version crate's requirement follows whatever your workspace
  version is.
- **Effort scales with LOC.** Step 1-3 are days. Step 4 is a campaign you
  schedule, or skip: the hygiene + supply-chain layers plus enforcement
  on everything new is already a massive upgrade over nothing.
