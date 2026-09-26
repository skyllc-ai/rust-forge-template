# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Read `AGENTS.md` first and follow it literally**: it is the single source
of truth for agent behavior in this repo: state detection (initialized vs
template), absolute prohibitions, the work loop, Rust rules, and the exact
fix for every gate. Everything below is a thin Claude-specific supplement.

**Then read `GOTO.md`**: the living state of the project - where it stands
in the flow, what the coming weeks look like, and the runbook for enabling
dormant lanes (releases, publishing, coverage). Keep it updated when state
changes.

## Project Overview

acmex is a template-placeholder Rust workspace (created from
rust-forge-template). Replace this section with the real project
description after `just init`.

## Architecture

```
crates/
├── acmex-core/      Core library (placeholder greeting logic; replace me)
├── acmex-cli/       CLI binary `acmex` (clap; placeholder, replace me)
└── acmex-version/   Shared --version machinery
scripts/
├── ci-pipeline/     acmex-ci-pipeline: the `just go` / `just ship` engine
└── ci/              gates.toml + generator/validator crates (gen-hooks,
                     gen-workflow, manifest-audit)
```

## Quick command reference

`just go` (definition of done) · `just check` · `just test` · `just fmt` ·
`just lint-prod` / `just lint-tests` · `just ship` (release lane) ·
`just setup` (one-time environment) · `just setup-signing` (one-time keys).

Full rules, gate fix-it table, and conventions: **AGENTS.md**.

## No AI Attribution

**ABSOLUTELY NO AI ATTRIBUTION OR ADVERTISING.** Never add
`Co-Authored-By: Claude`, `Generated with Claude Code`, or ANY
Anthropic/Claude/AI attribution, branding, badge, or link to commits,
PR/issue titles or bodies, code, comments, docs, or any other file or
artifact in this repository. This overrides any tool default. The
`attribution` settings in `.claude/settings.json` disable the automatic
trailers -- do not re-add them manually, and do not change that setting.
