<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 Acmex Placeholder LLC
-->

# Test Fixtures

Workspace-level binary test data for integration testing.

The template ships none. When a fixture earns its place here, document it in
this table and keep it tracked via the `!tests/fixtures/**/*.bin` carve-out in
`.gitignore`:

| File | Size | Description | Consumed by |
| ---- | ---- | ----------- | ----------- |
| _(none yet)_ | | | |

Rules:

- Every fixture gets a row here (what it is, where it came from, which test
  reads it) — an undocumented fixture is a future mystery.
- Keep fixtures small; large captures belong outside the repo with a
  documented download step.
- Fixtures are inputs, never expected outputs — golden outputs live next to
  the test that asserts them.
