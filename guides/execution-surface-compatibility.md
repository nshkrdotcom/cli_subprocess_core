# Execution Surface Compatibility

`cli_subprocess_core` now relies on
`ExternalRuntimeTransport.ExecutionSurface` for the actual transport contract.

Some downstream packages still type against the older
`CliSubprocessCore.ExecutionSurface` module name, especially where they:

- pattern-match on `%CliSubprocessCore.ExecutionSurface{}`
- accept a surface struct in public options
- validate placement metadata before invoking CLI runtimes

To keep those packages working without reintroducing transport ownership into
the core, `CliSubprocessCore.ExecutionSurface` remains as a compatibility
facade.

## What The Facade Does

The compatibility module preserves the historical struct shape:

- `surface_kind`
- `transport_options`
- `target_id`
- `lease_ref`
- `surface_ref`
- `boundary_class`
- `observability`

It delegates validation and capability lookup to
`ExternalRuntimeTransport.ExecutionSurface`.

## What The Facade Does Not Do

The compatibility module does not own:

- transport adapters
- process launch dispatch
- substrate capability definitions
- raw transport result types

Those still belong to `external_runtime_transport`.

## Preferred Caller Shapes

New callers should usually pass `execution_surface` as:

```elixir
execution_surface: [
  surface_kind: :ssh_exec,
  transport_options: [destination: "builder.example", ssh_user: "deploy"]
]
```

Compatibility callers may still pass:

```elixir
surface =
  CliSubprocessCore.ExecutionSurface.new!(
    surface_kind: :local_subprocess,
    target_id: "target-1",
    observability: %{route: :cli}
  )

CliSubprocessCore.Command.Options.new(
  provider: :gemini,
  prompt: "Say hello",
  execution_surface: surface
)
```

That keeps existing public contracts stable while routing all real validation
through the extracted transport package.
