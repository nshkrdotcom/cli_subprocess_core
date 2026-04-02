# Examples

These examples show the current public placement seam honestly: callers use
`CliSubprocessCore` APIs and describe placement with `execution_surface`.

## Included Examples

- `examples/command_over_execution_surface.exs` shows provider-aware command
  execution locally and the equivalent SSH placement shape.
- `examples/execution_surface_compatibility.exs` shows the compatibility
  `CliSubprocessCore.ExecutionSurface` struct flowing through the public
  command options API without taking transport ownership back from
  `external_runtime_transport`.
