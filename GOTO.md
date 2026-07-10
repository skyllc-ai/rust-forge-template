<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# GOTO.md: where we are, what's next, which switch does what

The **living state doc** for this project. `AGENTS.md` holds the rules and
`docs/forge/GETTING-STARTED.md` the how-to; this file holds the *state*: where the
project stands in the flow, the rhythm for daily work, what the coming weeks
look like, and the exact runbook for every dormant capability (release
artifacts, publishing, coverage, ...).

**Maintenance rule:** this file is a snapshot, not eternal truth. When a
checkbox flips, a lane goes live, or the plan changes, update it **in the
same PR**. A stale GOTO.md is worse than none.

> Fresh from `just init`? Section 1 describes the canonical post-bootstrap
> state: tick what `bootstrap.sh` completed for you, date the snapshot, and
> replace section 3 with your real plan as soon as you have one.

---

## 1. Where we are (snapshot: day 0, update me)

### The machine (bootstrap.sh walks all of these)

- [ ] Repo created from the template and cloned
- [ ] Init ceremony (`just init`): zero placeholder references remain
- [ ] Gate tools installed + git hooks wired (`just setup`)
- [ ] Commit signing configured (`just setup-signing`, `just doctor-signing` green)
- [ ] `just go` green (the definition of done for any change)
- [ ] Init state merged through the real flow (branch → PR → CI → auto-merge)
- [ ] GitHub-side state (`bash scripts/ci/bootstrap-github.sh`): labels, lane
      variables, merge settings, rulesets

### Pending (external / needs a human decision)

- [ ] **main-protection ruleset + merge queue**: needs a public repo or
      GitHub Pro/Team. When eligible: `bash scripts/ci/bootstrap-github.sh`
      (idempotent; also unlocks CodeQL uploads)
- [ ] Dependabot alerts + security updates: repo Settings → Code security
- [ ] If publishing is ever planned: reserve the crate name(s) on crates.io
      early (a placeholder publish is cheap; losing the name is not)
- [ ] License/commercial posture confirmed (default: MIT OR Apache-2.0);
      brand/trademark assets if any (see `lane:brand-assets`)

---

## 2. The rhythm (daily)

```bash
git switch -c feat/<topic>      # never work on main
# edit (you or the agent)
just check                      # seconds: compile + lint
just test                       # nextest suite
just go                         # the definition of done
git add -A && git commit -m "feat: ..."   # hooks run, ~2-15s
git push -u origin feat/<topic>           # gate battery, ~20-60s
gh pr create --fill && gh pr merge <branch> --auto
```

- Gate fails? `docs/forge/GETTING-STARTED.md` has the human fix-it table; `AGENTS.md` §6
  the agent version. Fix the cause, never bypass.
- Conventional Commits enforced (`feat: fix: docs: refactor: test: chore:`).
- Weekly, automatic: the tier-2 deep suite (miri, cargo-careful, mutation
  testing) runs on schedule; glance at its results when it lands.

**Agent session reading order:** `CLAUDE.md` → `AGENTS.md` → this file →
your design docs (put them under `docs/` and link them here).

---

## 3. What's next: your first weeks

Replace this section with your real milestone plan. Until then, the
canonical first moves for any project born from this template:

1. **Replace the placeholder** (`acmex-core`'s greeting logic and the CLI
   skeleton) with your first real module, following the existing style:
   doc comments everywhere, `Result` not `unwrap`, SPDX headers, files
   under 800 lines.
2. **Write the state you know into this file**: what the project is, the
   first milestone, its done-when criterion.
3. **Grow structure by recipe**, never by improvisation: new crates, fuzz
   targets, benches are `docs/forge/COMPONENTS.md` → `component:*` recipes; every one
   ends in `just go`.
4. **Cross-platform product?** Enable `lane:cross-lint` in week one (see
   §4): catching Windows/Linux target drift is cheap on day 1 and expensive
   after a month of macOS-only development.
5. **First ship**: when a binary is worth giving to anyone, flip
   `lane:release` and run `just ship`. Everything in between (versioning,
   changelog, release PR, tag build) is already wired.

---

## 4. Which switch does what (dormant lanes)

Everything below is **already installed and dormant**; enabling is a repo
variable plus, at most, a TOML flag. Full runbooks with verify steps:
`docs/forge/COMPONENTS.md`. This table is the quick map plus guidance on *when*.

| Lane | Turns on | How (short form) | When |
|---|---|---|---|
| `lane:cross-lint` | Windows (cargo-xwin) + Linux (zigbuild) lint/check gates | install the tools, add gate ids to `scripts/ci/gates.toml` tiers, `just acmex-gen-hooks` | Week one, if the product is cross-platform |
| `lane:release` | GitHub release binaries (3-target matrix, archives + SHA256SUMS) | `gh variable set LANE_RELEASE --body true`, then `just ship` | First shippable binary |
| `lane:slsa` | build provenance attestation on release artifacts (no secrets) | `gh variable set LANE_SLSA --body true` | Same moment as lane:release; it is free |
| `lane:release-plz` | automated version/changelog PRs on main | `gh variable set LANE_RELEASE_PLZ --body true` | Optional alternative to `just ship`-driven versioning; pick one driver |
| `lane:crates-publish` | crates.io publishing + weekly dry-run guard | reserve names, `CARGO_REGISTRY_TOKEN` secret, `LANE_CRATES=true`, per-crate flags | Only after the licensing/commercial decision |
| `lane:winget` | Windows package manager PRs per release | `WINGET_TOKEN` secret, `LANE_WINGET=true`, one manual first submission | After a v1 that Windows users install |
| `lane:codecov` | coverage upload + PR comments (90%/95% thresholds) | `CODECOV_TOKEN` secret, `LANE_CODECOV=true` | Once real logic exists; pointless for the skeleton |
| `lane:codeql` | SAST result uploads | auto-enables on public repos | With the go-public moment |
| `lane:brand-assets` | trademark-licensed brand files under `assets/brand/` | add `LicenseRef-*-Brand` license + assets | When a logo/brand exists |

---

## 5. Doc map (which doc for what)

| Question | Doc |
|---|---|
| What are the rules? (agents) | `AGENTS.md` (`CLAUDE.md` is the thin supplement) |
| How do I onboard a human / fix a gate? | `docs/forge/GETTING-STARTED.md` |
| Where are we, what's next, which switch? | **this file** |
| How do I grow the project (crates/lanes)? | `docs/forge/COMPONENTS.md` |
| Why is this lint/panic/dep rule strict? | `docs/policies/*.md` |
| Release mechanics internals | `scripts/ci-pipeline/src/` + `release-plz.toml` |
| Bringing this machinery to an existing repo | `docs/forge/ADOPTING.md` |
