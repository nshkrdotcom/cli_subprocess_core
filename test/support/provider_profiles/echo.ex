defmodule CliSubprocessCore.TestSupport.ProviderProfiles.Echo do
  @moduledoc false

  @behaviour CliSubprocessCore.ProviderProfile

  alias CliSubprocessCore.{Command, Event, Payload, ProcessExit}

  @impl true
  def id, do: :echo

  @impl true
  def capabilities, do: [:interrupt, :streaming]

  @impl true
  def build_invocation(opts) do
    {:ok,
     Command.new("echo-cli", ["run"],
       cwd: Keyword.get(opts, :cwd),
       env: %{"PROFILE" => "echo"}
     )}
  end

  @impl true
  def init_parser_state(opts) do
    %{opts: Enum.into(opts, %{}), seen: 0}
  end

  @impl true
  def decode_stdout(data, state) when is_binary(data) do
    event =
      Event.new(:assistant_delta,
        provider: id(),
        payload: Payload.AssistantDelta.new(content: data)
      )

    {[event], increment_seen(state)}
  end

  @impl true
  def decode_stderr(data, state) when is_binary(data) do
    event =
      Event.new(:stderr,
        provider: id(),
        payload: Payload.Stderr.new(content: data)
      )

    {[event], increment_seen(state)}
  end

  @impl true
  def handle_exit(reason, state) do
    exit = ProcessExit.from_reason(reason)

    payload =
      Payload.Result.new(
        status: if(ProcessExit.successful?(exit), do: :completed, else: :failed),
        stop_reason: exit.reason,
        output: %{code: exit.code, signal: exit.signal}
      )

    event = Event.new(:result, provider: id(), payload: payload)
    {[event], increment_seen(state)}
  end

  @impl true
  def transport_options(_opts), do: [startup_mode: :eager]

  defp increment_seen(state) do
    Map.update(state, :seen, 1, &(&1 + 1))
  end
end
