defmodule CliSubprocessCore.Channel.Delivery do
  @moduledoc """
  Stable mailbox-delivery metadata for direct channel subscribers.
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
