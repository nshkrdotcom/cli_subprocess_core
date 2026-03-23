defmodule CliSubprocessCore.Session.Delivery do
  @moduledoc """
  Stable mailbox-delivery metadata for direct session subscribers.

  The tagged event atom is configurable adapter detail. Higher-level wrappers
  should prefer their own relay envelope or `CliSubprocessCore.Session`
  extraction helpers over hard-coded assumptions about the default tag.
  """

  defstruct legacy_message: :session_event,
            tagged_event_tag: nil,
            tagged_payload: :event

  @type t :: %__MODULE__{
          legacy_message: :session_event,
          tagged_event_tag: atom(),
          tagged_payload: :event
        }

  @spec new(atom()) :: t()
  def new(tagged_event_tag) when is_atom(tagged_event_tag) do
    %__MODULE__{tagged_event_tag: tagged_event_tag}
  end
end
