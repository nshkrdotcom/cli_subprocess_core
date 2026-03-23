defmodule CliSubprocessCore.Transport.Delivery do
  @moduledoc """
  Stable mailbox-delivery metadata for transport subscribers.

  Direct adapters can use this metadata together with
  `CliSubprocessCore.Transport.extract_event/1` and
  `CliSubprocessCore.Transport.extract_event/2` to relay transport events
  without depending on internal worker identity.
  """

  defstruct legacy?: true,
            tagged_event_tag: nil

  @type t :: %__MODULE__{
          legacy?: true,
          tagged_event_tag: atom()
        }

  @spec new(atom()) :: t()
  def new(tagged_event_tag) when is_atom(tagged_event_tag) do
    %__MODULE__{tagged_event_tag: tagged_event_tag}
  end
end
