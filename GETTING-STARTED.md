<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# Getting Started — the zero-knowledge runbook

This guide assumes **nothing**: not Rust, not `just`, not GitHub CLI. Follow it
top to bottom and you end up with your own project running inside a
production-grade quality machine — strict lints, generated git hooks, tiered
CI, supply-chain checks — without assembling any of it yourself.

> **First, a fit check.** This machinery is overkill for tutorials, katas,
> and throwaway experiments — and gold for a project meant to live. Read
> "Is this template for you?" in the [README](README.md) (30 seconds) before
> proceeding.

## Completely new to git or GitHub?

You need three concepts before anything here makes sense. Don't learn them
from us — these are the canonical guides, and they are excellent:

| Concept | What it is for | Learn it here (15-30 min each) |
| --- | --- | --- |
| **git** | The version-control tool: every change to your code is recorded as a "commit" you can inspect, undo, and share. Everything in this template hangs off git. | [git-scm.com/book — chapters 1-2](https://git-scm.com/book/en/v2/Getting-Started-About-Version-Control) |
| **GitHub** | The hosting service where your repository lives online: backups, collaboration, pull requests, and the CI that re-checks your work. You need a (free) account. | [Create an account](https://github.com/signup), then [GitHub's Hello World](https://docs.github.com/en/get-started/start-your-journey/hello-world) |
| **SSH keys** | A key *pair*: the private half stays on your machine and does the signing/authenticating; the public half gets registered with GitHub so it can verify you. That is why setup always has two sides — local (create + configure) and GitHub (register). One key can serve both *authentication* (proving it's you when pushing) and *commit signing* (proving each commit came from you) — but GitHub registers those as two separate entries. | [GitHub: About SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/about-ssh) · [About commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification) |

Come back when those click — the rest of this guide automates nearly all of
the mechanics for you.

**The one rule of this template:** the gates are the law. When a commit or
push is rejected, the machine is telling you exactly what to fix. Fix the
cause; never bypass (`--no-verify` is treated as an incident, and the bundled
Claude Code guard blocks it outright).

---

## The fast lane — one guided command does Steps 0-4

`bootstrap.sh` drives the entire journey below, asking your consent at every
step: a docs gate (offers to open the fit check first), compiler
prerequisites, Homebrew (macOS), git/`just`/`gh`/`jq`/`pipx`+`reuse`, rustup,
GitHub login (an existing login is detected and reused), where the project
should live (smart default: your remembered `forge.projectsDir`, then
`ghq.root`, then existing conventional dirs like `~/Developer`; or pass
`--dir`), creating your repo from the template **or** cloning an existing
one, the init ceremony, gate tools + hooks, commit signing, and the first
green `just go`:

On a completely bare machine, before you have any repo (public repos —
for a private repo, download `bootstrap.sh` via the GitHub web UI and run
that instead):

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/bootstrap.sh | bash
```

If you already have the repo cloned:

```bash
bash bootstrap.sh
```

**Already-configured machines are respected — the script never erases your
setup.** Every step is check-before-act: tools you have are detected (at most
you get an optional update offer), your existing GitHub login is reused, a
working commit-signing configuration — GPG or SSH — is left completely
untouched (a configured-but-broken GPG setup is reported, never overwritten),
and your projects directory is remembered (`git config --global
forge.projectsDir`) so next time the right default is already there.
Unattended machines: see "Unattended / fleet provisioning" near the end of
this guide.

**Steps 0-4 below are the same journey as individual commands** — read them
to understand what the script does, or run them yourself if you prefer
manual control.

## Step 0 — Install the base tools (once per machine)

Compiler prerequisites, package manager, and the CLI tools, by hand:

macOS: `xcode-select --install`, then [Homebrew](https://brew.sh), then
`brew install just gh jq pipx && pipx install reuse`.
Linux (Debian/Ubuntu): `sudo apt install build-essential curl git jq pipx`,
`pipx install reuse`, plus [`just`](https://github.com/casey/just#packages)
and [`gh`](https://cli.github.com). Both: install Rust via
[rustup](https://rustup.rs), then authenticate with `gh auth login`.

You do **not** need to pick a Rust version — the repo pins its own toolchain
in `rust-toolchain.toml`, and rustup installs it automatically on first build.

## Step 0.5 — Set up commit signing (required, one command)

The pre-push gate verifies that **every commit is signed** — a hard gate, so
do this before your first push, not after it rejects you. Everything that
can be automated, is:

```bash
just setup-signing
```

That single command: generates an SSH key if you have none (you choose the
passphrase), configures git to sign every commit and tag with it, registers
the public half on GitHub as a signing key via the API, and finishes with
`just doctor-signing` to prove the whole chain. Idempotent — re-run it any
time; it never overwrites an existing key.

The only case needing a manual step: if `gh` says its token lacks the
signing-key scope, run `gh auth refresh -h github.com -s admin:ssh_signing_key`
and re-run the recipe.

Classic GPG works too (configure `user.signingkey <KEYID>` yourself);
`just doctor-signing` diagnoses either setup, and `just sign-branch` can
rescue a branch that accumulated unsigned commits.

---

## Step 1 — Get the code onto your machine

**Starting a NEW project** — create your own repo from the template
(GitHub copies the files with a fresh history; no coupling, no fork
relationship) and clone it in one command:

```bash
gh repo create my-org/myproj --template <owner>/rust-forge-template --private --clone
cd myproj
```

**Joining an EXISTING project** that was built from this template — just
clone it (either form works; `gh` picks the right protocol for you):

```bash
gh repo clone my-org/myproj        # or: git clone git@github.com:my-org/myproj.git
cd myproj
```

Joiners skip Step 2 (the project is already initialized) and go straight to
Step 3.

## Step 2 — Run the init ceremony (once, ever)

The repo arrives under the placeholder identity `acmex`. One command rewrites
it to yours — file contents, file names, manifests, workflows, licenses:

```bash
just init myproj my-org "My Org LLC" "Me <me@example.com>"
```

It finishes by asserting that **zero** placeholder references survive, then
deletes itself. If `rg -i acmex` prints nothing, the ceremony worked.

The project starts dual-licensed **MIT OR Apache-2.0**. To use a different
license, pass it as the sixth positional argument
(`just init myproj my-org "My Org LLC" "Me <m@e.x>" "" "BSD-3-Clause"`) —
the ceremony rewrites every
SPDX header and manifest, then the `reuse` gate stays red until you put the
matching text(s) into `LICENSES/` (it prints the exact steps).

## Step 3 — Set up your environment (once per machine)

```bash
just setup
```

This installs the pinned toolchain, every tool the gates call
(`cargo-nextest`, `cargo-deny`, `cargo-vet`, `cargo-machete`, `typos`,
`taplo`, ...), wires the git hooks, and smoke-checks the workspace.
Idempotent — re-run it any time.

Build caching is **resilient**: every `just`-driven build (recipes, hooks,
the go/ship pipeline) auto-detects an installed, functional `sccache` and
uses it — and silently runs stock Cargo when it is absent. `just setup`
installs sccache, so you get warm-cache speed from day one without the repo
ever *requiring* it. Plain `cargo` invocations stay stock unless you opt in
user-level: see "Performance tuning (optional)" at the end of this guide.

## Step 4 — Prove the machine

```bash
just go
```

Green means: toolchain pinned, file sizes in policy, all tests pass, doc-tests
pass, production and test lints clean, dependencies vetted and license-clean,
docs build without warnings. This is your "everything is fine" button —
run it whenever you want certainty.

## Step 5 — Create the GitHub-side state

A template copies files only. Rulesets, labels, and lane switches live
server-side:

```bash
bash scripts/ci/bootstrap-github.sh
```

Note: the branch ruleset (PR-required, required status checks, **merge
queue**) needs a public repo or GitHub Pro/Team — on a private free-plan repo
the script tells you and skips that part; re-run it when you go public. The
same applies to CodeQL uploads (auto-enables on public repos).

---

## Daily life (the vibe-coding loop)

```bash
# 1. Make changes (you, or your AI assistant — CLAUDE.md is pre-wired)
# 2. Quick feedback while working:
just check          # compile + lint sweep, seconds
just test           # full test suite via nextest
# 3. Commit — the pre-commit hook runs automatically (~2-15 s)
git add -A && git commit -m "feat: describe the change"
# 4. Push — the pre-push hook runs the big battery (~20-60 s)
git switch -c feat/my-change   # never commit to main directly
git push -u origin feat/my-change
# 5. Open a PR — CI runs the same gates, plus more
gh pr create --fill
```

Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`,
`refactor:`, `test:`, `chore:`); the commit-msg hook rejects anything else,
and `git commit` with no `-m` shows a template.

### When a gate fails

The failing gate prints its name. Reproduce it locally, fix the cause, retry:

| Gate | What it checks | Typical fix |
| --- | --- | --- |
| `fmt` / `fmt-check` | rustfmt formatting | `just fmt` |
| `lint-prod` / `lint-tests` / `lint-ci` | the strict clippy posture | read the lint's suggestion; if the code is genuinely right, use `#[expect(lint_name, reason = "...")]` — never `allow` |
| `tests` / `smoke` / doc-tests | test suite | `just test`, fix the failure |
| `typos` | spelling | fix the typo, or add a real domain word to `.typos.toml` |
| `taplo` | TOML formatting | `taplo fmt` |
| `reuse` | SPDX license headers | copy the 2-line header from any neighbouring file |
| `file-size` | source files ≤ 800 lines | split the module (or document an exception in `scripts/ci/file_size_exceptions.txt`) |
| `deny` | licenses / advisories / bans | `cargo deny check` — usually a new dep with an unvetted license |
| `vet` | supply-chain audits | `cargo vet` and follow its suggestions (imports cover most crates; otherwise `cargo vet add-exemption`) |
| `machete` | unused dependencies | remove the dep from `Cargo.toml` |
| `gates-drift` / `hooks-drift` / `fast-drift` | generated hooks match `gates.toml` | edit `scripts/ci/gates.toml` (never the `_lint_*.sh` files), then `just acmex-gen-hooks` |
| `workflow-drift` | `pr-fast.yml` matches `gates.toml` | keep the two in sync — the error names the exact mismatch |
| `manifest-drift` | crate manifests inherit from the workspace | use `field.workspace = true` and `dep.workspace = true` |
| `commit-subjects` | Conventional Commits | reword the commit (`git commit --amend`) |
| `rustdoc` | docs build, no broken links | fix the doc comment the error points at |

### Vibe coding with an AI assistant

`CLAUDE.md` already tells Claude Code how this repo works (commands, lint
rules, conventions, "never edit generated hooks", "never bypass gates" — the
last one is mechanically enforced by `.claude/settings.json`). Useful prompts:

- *"Run `just go` and fix everything it complains about."*
- *"Add a `<feature>` module to `<project>-core` following the existing
  Greeting example's conventions, with tests and doc-tests."*
- *"Add crate X as a dependency — workspace-style — and make the vet and deny
  gates pass."*
- *"Follow COMPONENTS.md → component:new-crate and scaffold a `<name>` crate."*

The gates are what make this safe: whatever gets generated must still pass
the same machine you do.

---

## Growing the project

- **Add structure** (crates, benches, fuzz targets): follow the recipes in
  [`COMPONENTS.md`](COMPONENTS.md). Every recipe ends in `just go`.
- **Switch on dormant machinery** (GitHub releases, crates.io publishing,
  winget, codecov, SLSA): each is a `lane:*` entry in `COMPONENTS.md` —
  activation is a repo variable plus, at most, a TOML flag. Nothing needs to
  be built.
- **Ship**: `just ship` validates, bumps the version, rolls the changelog,
  opens an auto-merging release PR. (Enable `LANE_RELEASE` first if you want
  merged release PRs to build binaries.)

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `cargo nextest: command not found` | `just setup` |
| First build downloads a whole toolchain | Expected — `rust-toolchain.toml` pins a specific nightly; rustup fetches it once |
| Commit succeeded without any hook output | Hooks not wired: `just install-hooks` |
| `reuse: command not found` in hook output | Soft-skip; `pipx install reuse` to enable the gate |
| Push rejected: `vet-audit-discipline` | You changed an exemption version without an audit — see `scripts/ci/vet_bump.sh` and CONTRIBUTING's supply-chain section |
| CI job "Analyze (rust)" skipped | CodeQL needs a public repo (or GHAS + `LANE_CODEQL=true`) — by design |
| No merge queue on PRs | Rulesets need a public repo or GitHub Pro/Team — re-run `bootstrap-github.sh` once eligible |
| `just: command not found` on Windows | Use `winget install Casey.Just`; hooks run under Git-Bash |

Still stuck? `just` (no arguments) lists every available command with a
one-line description.

---

## Unattended / fleet provisioning (`--yes`)

Provisioning many workstations (MDM, Ansible, CI runners)? `bootstrap.sh`
has an unattended lane:

```bash
export GH_TOKEN=<fine-grained PAT>        # gh honors it automatically
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/bootstrap.sh   | bash -s -- --yes --join my-org/myproj --dir ~/work
```

What `--yes` does: auto-approves every step, installs missing tools (skips
optional updates for reproducibility), clones the repo, runs `just setup`.
What it deliberately does **not** do: generate signing keys. Key issuance is
an identity decision — pre-provision `~/.ssh/id_ed25519` through your fleet
tooling (then the signing step wires it up non-interactively), or leave it
to each developer's first `just setup-signing`. The script reports loudly
either way, so an unsigned machine cannot silently look "done".

At real fleet scale, consider baking the environment instead of scripting
it — a devcontainer/Nix image is the natural next step (a future
`COMPONENTS.md` recipe).

## Performance tuning (optional)

The repo deliberately ships **stock Cargo behavior**; speed-ups are personal,
machine-level choices in `~/.cargo/config.toml` (never committed):

Ready-made, fully commented samples ship in the repo — copy the parts you
want into your HOME config (they are inert where they sit):

- **`.cargo/macos.sample.toml`** — sccache, per-project target-dir redirects,
  `target-cpu=native`, frame pointers, mold linker, dev-profile speedups
- **`.cargo/windows.sample.toml`** — sccache, Dropbox/OneDrive-safe target
  dir, rust-lld, Defender exclusions

Helpers: `just setup-sccache` (install + cache stats), `just sccache-stats`.
Note that `just`-driven builds already use sccache automatically whenever it
is installed — the user-level config extends that to plain `cargo` and your
IDE's builds.

A warning from experience: redirecting `target-dir` to a shared location
(e.g. `/tmp/rust-target`) makes `cargo clean` and repo deletion stop
reclaiming space — the shared cache silently grows by hundreds of GB across
workspaces until the volume fills and everything on the machine starts
failing with "no space left on device". If you must redirect, put it on a
volume you monitor.
