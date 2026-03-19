defmodule CliSubprocessCore.TestSupport.ProviderProfiles.DuplicateEcho do
  @moduledoc false

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.Command

  @impl true
  def id, do: :echo

  @impl true
  def capabilities, do: [:batch]

  @impl true
  def build_invocation(_opts), do: {:ok, Command.new("duplicate-echo")}

  @impl true
  def init_parser_state(_opts), do: :duplicate

  @impl true
  def decode_stdout(_data, state), do: {[], state}

  @impl true
  def decode_stderr(_data, state), do: {[], state}

  @impl true
  def handle_exit(_reason, state), do: {[], state}

  @impl true
  def transport_options(_opts), do: []
end
