{:ok, local_result} =
  CliSubprocessCore.Command.run(
    provider: :claude,
    prompt: "Summarize this repository"
  )

IO.puts("local output: #{local_result.output}")

# To move the same provider command onto a different execution surface, keep
# the public API the same and change only `execution_surface`.
#
# {:ok, remote_result} =
#   CliSubprocessCore.Command.run(
#     provider: :codex,
#     prompt: "Review the latest diff",
#     execution_surface: [
#       surface_kind: :ssh_exec,
#       transport_options: [
#         destination: "buildbox.example",
#         ssh_user: "deploy"
#       ]
#     ]
#   )
#
# IO.puts("remote output: #{remote_result.output}")
