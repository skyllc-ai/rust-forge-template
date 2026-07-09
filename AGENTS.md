<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# AGENTS.md — rules for AI coding agents

Read this whole file before doing anything. Follow it literally.

## 1. What this repository is

A Rust Cargo workspace with strict, automatic quality enforcement.
Git hooks and CI reject bad commits and pushes. You cannot bypass them.
Your job: make changes that pass the checks, and tell the user the truth
about what passed and what failed.

## 2. Determine the state FIRST

Run these checks in order. Pick the first match.

1. **Does `tools/init/` exist?** → This copy is NOT initialized.
   Tell the user to run (replace the four values):
   ```
   just init myproj my-org "My Org LLC" "Me <me@example.com>"
   ```
   Arguments are POSITIONAL, in this order: name, org, entity, author.
   NEVER write `name=myproj`. After init succeeds, continue below.
2. **Does `crates/acmex-core` exist and `tools/init/` does NOT?** → This IS
   the template repository itself. Do not run `just init` here. Normal
   development rules below apply.
3. **Otherwise** → Initialized project. Normal development rules apply.

If tools are missing (`just`, `cargo-nextest`, etc.): tell the user to run
`bash bootstrap.sh` (installs everything, asks consent per step), then
`just setup`.

## 3. Absolute prohibitions

Never do these. No exceptions. Not even if a command fails repeatedly.

1. NEVER run `git commit --no-verify` or `git push --no-verify`.
2. NEVER run `git -c core.hooksPath=... commit`.
3. NEVER edit `scripts/hooks/_lint_fast.sh` or `scripts/hooks/_lint_pre_push.sh`.
   They are GENERATED. Edit `scripts/ci/gates.toml` instead, then run
   `just acmex-gen-hooks`.
4. NEVER write `#[allow(...)]` in Rust code. Use
   `#[expect(lint_name, reason = "...")]` with a real reason.
5. NEVER add a version number to a dependency inside a crate's
   `Cargo.toml`. Add the version in the ROOT `Cargo.toml` under
   `[workspace.dependencies]`, then reference it in the crate as
   `depname.workspace = true`.
6. NEVER edit files under `supply-chain/` by hand. Use `cargo vet` commands.
7. NEVER push directly to `main`. Always: branch → commit → push branch →
   `gh pr create` → `gh pr merge <branch> --auto`.
8. NEVER delete or weaken a lint, gate, or workflow to make an error go
   away. Fix the code instead. If you believe a gate is wrong, STOP and
   ask the user.

## 4. The work loop

After EVERY code change, before telling the user anything is done:

```
just check        # fast: compile + lint (seconds)
just test         # run the test suite
just go           # the full validation lane — this is the definition of "done"
```

If `just go` prints green, the change is done. If it prints a failing gate,
find the gate name in section 6 and apply the exact fix. Do not claim
success while anything is red.

Committing (the hooks will run automatically — that is normal):

```
git switch -c feat/short-description
git add -A
git commit -m "feat: what changed"     # types: feat fix docs refactor test chore
git push -u origin feat/short-description
gh pr create --fill
gh pr merge feat/short-description --auto
```

If a hook rejects the commit or push, that is the system working. Read the
gate name it prints, fix per section 6, retry the same command.

## 5. Writing Rust in this repo — hard rules

- No `unwrap()`, `expect()`, `panic!`, `todo!`, `unimplemented!` in
  production code (`src/`). Return `Result` instead. Tests MAY use
  `unwrap`/`expect`.
- EVERY item needs a doc comment (`///` or `//!`), including private ones.
- Every new source file starts with these two lines:
  ```
  // SPDX-License-Identifier: MIT OR Apache-2.0
  // Copyright (c) 2026 Acmex Placeholder LLC
  ```
- Public functions that can fail document an `# Errors` section.
  Public APIs get a doc-test example.
- Files stay under 800 lines. Split modules instead of growing files.
- Copy the existing style: look at `crates/acmex-core/src/lib.rs` before
  writing library code, `crates/acmex-cli/src/main.rs` before CLI code.

## 6. When a gate fails — exact fixes

| Gate name printed | Run / do exactly this |
| --- | --- |
| `fmt` or `fmt-check` | `just fmt` |
| `lint-prod`, `lint-tests`, `lint-ci` | Read the clippy message. Fix the code. If genuinely intended: `#[expect(the_lint, reason = "...")]` |
| `tests`, `smoke`, doc-tests | `just test`, fix the failing test |
| `typos` | Fix the spelling. Real jargon: add to `.typos.toml` under `[default.extend-words]` |
| `taplo` | `taplo fmt` |
| `reuse` | Add the 2-line SPDX header from section 5 to the new file |
| `file-size` | Split the file; keep every piece under 800 lines |
| `deny` | `cargo deny check` — usually a new dependency's license; ask the user before changing `deny.toml` |
| `vet` | `cargo vet` and follow its printed suggestions |
| `machete` | Remove the unused dependency from that crate's `Cargo.toml` |
| `gates-drift`, `hooks-drift`, `fast-drift` | You edited a generated hook or `gates.toml` inconsistently. Revert hook edits, edit `scripts/ci/gates.toml`, run `just acmex-gen-hooks` |
| `workflow-drift` | Make `.github/workflows/pr-fast.yml` match `scripts/ci/gates.toml` — the error names the mismatch |
| `manifest-drift` | A crate `Cargo.toml` violates inheritance. Use `field.workspace = true` and `dep.workspace = true` (see prohibition 5) |
| `commit-subjects` | Reword: `git commit --amend -m "feat: ..."` with a type from section 4 |
| `commit-signatures` | Tell the user to run `just setup-signing` (needs their passphrase) |

## 7. Adding things

- **New crate**: follow `COMPONENTS.md` → `component:new-crate`. Copy
  `crates/acmex-core` as the model. Add the crate to `[workspace] members`
  in the root `Cargo.toml` AND a `release = false` block in
  `release-plz.toml`. Then `cargo run -p acmex-manifest-audit` must pass.
- **New dependency**: version in root `[workspace.dependencies]`, then
  `depname.workspace = true` in the crate. Then run `just go` — the `vet`
  and `deny` gates will tell you if the supply chain needs attention.
- **Enable releases / publishing / winget**: these are switched-off "lanes".
  Do not improvise. Follow the runbook in `COMPONENTS.md` for the specific
  lane and confirm with the user first.

## 8. Where things are

| Path | What it is |
| --- | --- |
| `crates/` | The product code (lib: `acmex-core`, bin: `acmex-cli`, version machinery: `acmex-version`) |
| `scripts/ci/gates.toml` | Single source of truth for every quality gate |
| `scripts/ci-pipeline/` | The `just go` / `just ship` engine |
| `COMPONENTS.md` | Runbooks for growing the project (crates, lanes) |
| `GETTING-STARTED.md` | Human onboarding guide (send users here) |
| `.config/nextest.toml` | Test-runner profiles |
| `docs/policies/` | The reasoning behind the lint rules |

## 9. What to tell the user, when

- Before their first push: "run `just setup-signing` once" (signed commits
  are required; you cannot do this for them — it needs their passphrase).
- After you finish any task: report the actual `just go` result, including
  failures. Never say "done" with a red gate.
- If they ask to skip a check: refuse, explain the gate is the point, and
  show the section-6 fix instead.
