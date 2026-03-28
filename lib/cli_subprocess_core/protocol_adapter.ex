defmodule CliSubprocessCore.ProtocolAdapter do
  @moduledoc """
  Pure codec and protocol-state boundary used by `CliSubprocessCore.ProtocolSession`.

  Adapters own protocol encoding, decoding, correlation mapping, and readiness
  classification. They do not own processes, timers, pending-request tables, or
  transport lifecycle.
  """

  @type correlation_key :: term()

  @type inbound_event ::
          {:ready, term()}
          | {:response, correlation_key(), {:ok, term()} | {:error, term()}}
          | {:peer_request, correlation_key(), term()}
          | {:notification, term()}
          | {:protocol_error, term()}
          | {:fatal_protocol_error, term()}
          | :ignore

  @callback init(keyword()) ::
              {:ok, adapter_state :: term(), startup_frames :: [binary()]}
              | {:error, reason :: term()}

  @callback encode_request(term(), adapter_state :: term()) ::
              {:ok, correlation_key(), frame :: binary(), adapter_state :: term()}
              | {:error, reason :: term()}

  @callback encode_notification(term(), adapter_state :: term()) ::
              {:ok, frame :: binary(), adapter_state :: term()}
              | {:error, reason :: term()}

  @callback handle_inbound(binary(), adapter_state :: term()) ::
              {:ok, [inbound_event()], adapter_state :: term()}
              | {:error, reason :: term()}

  @callback encode_peer_reply(
              correlation_key(),
              {:ok, term()} | {:error, term()},
              adapter_state :: term()
            ) ::
              {:ok, frame :: binary(), adapter_state :: term()}
              | {:error, reason :: term()}
end
