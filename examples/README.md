# Examples

These examples show the current public placement seam honestly: callers use
`CliSubprocessCore` APIs and describe placement with `execution_surface`.

## Included Examples

- `examples/command_over_execution_surface.exs` shows provider-aware command
  execution locally and the equivalent SSH placement shape.
- `examples/execution_surface_compatibility.exs` shows the compatibility
  `CliSubprocessCore.ExecutionSurface` struct flowing through the public
  command options API without taking transport ownership back from
  `execution_plane`.
- `examples/tool_descriptor_validation.exs` shows neutral tool descriptor,
  request, and response validation without spawning a provider CLI or adding
  host tool execution to core.

## Hardening Notes

The emergency hardening work in this repo is primarily profile and contract work, so the strongest
example surface is the provider-profile test lane:

- `test/cli_subprocess_core/provider_profiles_test.exs`

That suite now proves that the shared transport options preserve chunk-first overflow controls
instead of dropping them at the profile boundary.
