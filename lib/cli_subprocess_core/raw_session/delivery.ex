defmodule CliSubprocessCore.RawSession.Delivery do
  @moduledoc """
  Stable mailbox-delivery metadata for raw-session consumers.

  Raw sessions are a direct adapter surface above the transport. This metadata
  exposes the effective receiver, subscription ref, and tagged event atom
  without requiring callers to infer them from transport internals.
  """

  defstruct receiver: nil,
            transport_ref: nil,
            tagged_event_tag: nil

  @type t :: %__MODULE__{
          receiver: pid(),
          transport_ref: reference(),
          tagged_event_tag: atom()
        }

  @spec new(pid(), reference(), atom()) :: t()
  def new(receiver, transport_ref, tagged_event_tag)
      when is_pid(receiver) and is_reference(transport_ref) and is_atom(tagged_event_tag) do
    %__MODULE__{
      receiver: receiver,
      transport_ref: transport_ref,
      tagged_event_tag: tagged_event_tag
    }
  end
end
