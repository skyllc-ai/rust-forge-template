<!--
SPDX-License-Identifier: MIT OR Apache-2.0
Copyright (c) 2026 SKY, LLC.
-->

# Operator notes (template maintainers only)

This file lives under `tools/init/`, which **deletes itself in every child
repository** during the init ceremony - so these notes exist only in the
template itself and never reach initialized projects.

## Finding every repo born from the forge

Each child carries a quiet provenance record at
`docs/forge/FORGE-STAMP.toml` (init rewrites its `project` field). The
child-facing docs deliberately do not advertise how to search for it.

- GitHub code search (covers your private repos too, when authenticated):
  `path:docs/forge/FORGE-STAMP.toml`
- or the stamp string:
  `"forged-from = \"skyllc-ai/rust-forge-template\""`
- filter by owner as needed: `org:skyllc-ai path:docs/forge/FORGE-STAMP.toml`

Note the honest limits: on public children the stamp file is world-readable
(anyone can run the same search), and truly hostile forks can delete it.
The stamp is a convenience for fleet-wide template updates, not a security
or license-enforcement mechanism.

## Related conventions

- `docs/forge/TEMPLATE_VERSION` is the baseline for update diffs; bump it
  with template releases.
- A public repo *topic* (`rust-forge-template`) was considered as a second
  breadcrumb and deliberately rejected: topics are displayed on every
  child's repo homepage, which advertises the lineage. If a child wants to
  credit the template publicly, that is their call, not the bootstrap's.
