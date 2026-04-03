surface =
  CliSubprocessCore.ExecutionSurface.new!(
    surface_kind: :local_subprocess,
    target_id: "compat-target",
    observability: %{route: :cli_endpoint},
    transport_options: [startup_mode: :lazy]
  )

{:ok, options} =
  CliSubprocessCore.Command.Options.new(
    provider: :gemini,
    prompt: "Say hello",
    execution_surface: surface
  )

IO.inspect(surface, label: "compatibility surface")
IO.inspect(CliSubprocessCore.ExecutionSurface.to_map(surface), label: "compatibility surface map")

IO.inspect(
  %{
    provider: options.provider,
    target_id: options.target_id,
    observability: options.observability,
    provider_options: options.provider_options
  },
  label: "command options"
)
