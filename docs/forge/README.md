<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# docs/forge: the template's machinery docs (and provenance stamp)

This directory is the **permanent home of the scaffolding documentation**
that ships with [rust-forge-template](https://github.com/skyllc-ai/rust-forge-template),
and the marker of this repository's template lineage:

| File | What it is |
| --- | --- |
| `FORGE-STAMP.toml` | Provenance record used by template-update tooling (do not delete) |
| `TEMPLATE_VERSION` | The template baseline this project started from |
| `GETTING-STARTED.md` | Zero-knowledge onboarding: tools, signing, init, daily loop, gate fix-it table |
| `COMPONENTS.md` | The growth catalog: dormant `lane:*` switches and `component:*` recipes |
| `ADOPTING.md` | Bringing this machinery to an existing project |

Project-specific docs do **not** belong here; put those under `docs/`
(e.g. `docs/architecture/`, alongside `docs/policies/`). Keeping this
directory template-only is what makes future template updates a clean
diff against a known baseline instead of a merge puzzle.

Root files that intentionally stay at the repo root, because tooling and
ecosystem conventions look for them there: `README.md`, `LICENSE`,
`CHANGELOG.md`, `SECURITY.md`, `CITATION.cff`, `TRADEMARK.md`,
`AGENTS.md` (agents.md standard), `CLAUDE.md` (auto-loaded by Claude
Code), `GOTO.md` (the living project-state doc), `docs/CONTRIBUTING.md`
(one of GitHub's three recognized locations), and the curl-published
entry scripts (`bootstrap.sh`, `adopt.sh`, `install.sh`).
