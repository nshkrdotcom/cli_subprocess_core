# External Runtime Transport

`cli_subprocess_core` now sits directly above `execution_plane`.

That means:

- provider planning lives in `cli_subprocess_core`
- the covered `:local_subprocess` one-shot command lane now runs through `execution_plane`
- raw local and non-local process placement now runs through `ExecutionPlane.Process.Transport`
- the public seam between them is `execution_surface`
- `external_runtime_transport` remains as a compatibility projection package for
  historical public structs that some downstream callers still consume

## Shared Placement Contract

The core accepts one public placement value:

- `contract_version`
- `surface_kind`
- `transport_options`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`

The core passes that contract to the lower owner for the chosen lane without
leaking adapter module names into its own public API. For the covered local
one-shot lane that owner is `ExecutionPlane.Process`; for the raw and
session-bearing surfaces it is `ExecutionPlane.Process.Transport`.

For downstream compatibility, `CliSubprocessCore.ExecutionSurface` remains as a
thin facade over the same transport-owned contract. It preserves the legacy
struct/module identity without moving transport ownership back into the core.

Use `CliSubprocessCore.ExecutionSurface.to_map/1` when a caller needs the
versioned map projection for a boundary or fixture.

## What The Core Gets Back

The raw/session transport substrate returns Execution Plane-owned runtime data.
`cli_subprocess_core` may project that data back into compatibility types such
as:

- `ExternalRuntimeTransport.Transport.RunResult`
- `ExternalRuntimeTransport.Transport.Info`
- `ExternalRuntimeTransport.Transport.Error`
- `ExternalRuntimeTransport.ProcessExit`

`cli_subprocess_core` wraps those types where necessary with provider context.
For the covered one-shot command lane it instead projects the outcome into the
core-owned `CliSubprocessCore.Command.RunResult`.

## Landed Surface Kinds

The landed built-in kinds are:

- `:local_subprocess`
- `:ssh_exec`
- `:guest_bridge`

From the core’s point of view, these are just supported placement values on
`execution_surface`.

## Why The Split Exists

The extraction keeps the CLI core focused on:

- provider profile contracts
- model and runtime policy
- normalized event emission
- session and channel behavior

while letting non-CLI stacks reuse the same execution substrate directly.
