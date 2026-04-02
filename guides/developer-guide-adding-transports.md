# Developer Guide: Adding Transports

`cli_subprocess_core` no longer owns built-in transport families.

If you need to add or change a built-in execution surface such as a new
`surface_kind`, the change belongs in `external_runtime_transport`.

## Ownership Rule

Transport-family ownership lives in:

- `ExternalRuntimeTransport.ExecutionSurface`
- `ExternalRuntimeTransport.ExecutionSurface.Adapter`
- the external adapter registry
- `ExternalRuntimeTransport.Transport.*`

`cli_subprocess_core` owns provider/runtime behavior above that substrate.

## What Stays In This Repo

Changes belong in `cli_subprocess_core` when they affect:

- provider CLI command construction
- provider stdout/stderr parsing
- normalized event and payload emission
- model policy
- session or channel behavior
- provider-facing runtime errors

## What Leaves This Repo

Changes belong in `external_runtime_transport` when they affect:

- a new built-in `surface_kind`
- adapter capability declarations
- raw process startup and shutdown contracts
- transport `run/2`, streaming IO, or bridge protocol logic
- transport-owned result and error types

## Public Seam

The core must keep using one public placement seam:

- `execution_surface`

It must not expose adapter module selection publicly.

When the substrate gains a new landed surface, the core should normally only
need:

- documentation updates
- examples
- any provider-side path-semantics or runtime-failure refinements
