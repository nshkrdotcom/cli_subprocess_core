# External Runtime Transport

`cli_subprocess_core` sits above `external_runtime_transport`.

That means:

- provider planning lives in `cli_subprocess_core`
- raw process placement lives in `external_runtime_transport`
- the public seam between them is `execution_surface`

## Shared Placement Contract

The core accepts one public placement value:

- `surface_kind`
- `transport_options`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`

The core passes that contract to `ExternalRuntimeTransport.ExecutionSurface`
without leaking adapter module names into its own public API.

For downstream compatibility, `CliSubprocessCore.ExecutionSurface` remains as a
thin facade over the same transport-owned contract. It preserves the legacy
struct/module identity without moving transport ownership back into the core.

## What The Core Gets Back

The transport substrate returns transport-owned types such as:

- `ExternalRuntimeTransport.Transport.RunResult`
- `ExternalRuntimeTransport.Transport.Info`
- `ExternalRuntimeTransport.Transport.Error`
- `ExternalRuntimeTransport.ProcessExit`

`cli_subprocess_core` wraps those types where necessary with provider context,
but it does not re-own them.

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
