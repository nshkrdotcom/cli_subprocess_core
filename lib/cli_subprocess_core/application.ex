defmodule CliSubprocessCore.Application do
  @moduledoc """
  OTP application supervision tree for the core runtime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: CliSubprocessCore.TaskSupervisor},
      {CliSubprocessCore.ProviderRegistry,
       name: CliSubprocessCore.ProviderRegistry,
       profile_modules: CliSubprocessCore.built_in_profile_modules()}
    ]

    opts = [strategy: :one_for_one, name: CliSubprocessCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
