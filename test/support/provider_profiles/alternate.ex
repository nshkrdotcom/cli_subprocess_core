defmodule CliSubprocessCore.TestSupport.ProviderProfiles.Alternate do
  @moduledoc false

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.{Command, Event, Payload}

  @impl true
  def id, do: :alternate

  @impl true
  def capabilities, do: [:batch]

  @impl true
  def build_invocation(_opts) do
    {:ok, Command.new("alternate-cli", ["invoke"])}
  end

  @impl true
  def init_parser_state(_opts), do: :alternate_state

  @impl true
  def decode_stdout(data, state) do
    event =
      Event.new(:assistant_message,
        provider: id(),
        payload: Payload.AssistantMessage.new(content: [data], model: "alternate")
      )

    {[event], state}
  end

  @impl true
  def decode_stderr(data, state) do
    event =
      Event.new(:stderr,
        provider: id(),
        payload: Payload.Stderr.new(content: data)
      )

    {[event], state}
  end

  @impl true
  def handle_exit(_reason, state) do
    {[], state}
  end

  @impl true
  def transport_options(_opts), do: []
end
