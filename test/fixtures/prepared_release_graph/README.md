# Prepared Release Graph Fixture

This fixture compiles every prepared first-party package behind top-level path
overrides. It is intentionally incomplete until
`scripts/prepared_release_graph_ci.sh` copies it to a temporary directory and
generates `workspace_paths.exs` from an explicit `--workspace-root` argument.
The runner activates the Mix project, fixture library, and test templates only
in that temporary project so the owning repository's own `mix test` does not
load fixture-only SDK modules.

The runner executes two variants:

- canonical source paths for local integration;
- isolated paths unpacked from freshly built Hex tarballs, with ordinary
  sibling discovery unavailable.

Both variants are offline with respect to provider services and credentials.
They exercise only bounded local subprocesses.
