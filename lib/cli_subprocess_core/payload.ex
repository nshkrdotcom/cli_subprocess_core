defmodule CliSubprocessCore.Payload do
  @moduledoc """
  Namespace for the normalized runtime payload structs emitted by the core.
  """

  @doc false
  defmacro __using__(defaults: defaults) do
    quote bind_quoted: [defaults: defaults] do
      defstruct defaults

      @spec new(keyword() | map()) :: struct()
      def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
        attrs =
          attrs
          |> Enum.into(%{})
          |> Map.update(:metadata, %{}, &CliSubprocessCore.Payload.normalize_metadata/1)

        struct(__MODULE__, attrs)
      end
    end
  end

  @doc false
  @spec normalize_metadata(term()) :: map()
  def normalize_metadata(metadata) when is_map(metadata), do: metadata
  def normalize_metadata(_metadata), do: %{}
end

defmodule CliSubprocessCore.Payload.RunStarted do
  @moduledoc "Marks the start of a provider CLI run."

  use CliSubprocessCore.Payload,
    defaults: [provider_session_id: nil, command: nil, args: [], cwd: nil, metadata: %{}]

  @type t :: %__MODULE__{
          provider_session_id: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          cwd: String.t() | nil,
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.AssistantDelta do
  @moduledoc "Represents a streamed assistant delta."

  use CliSubprocessCore.Payload, defaults: [content: "", index: nil, format: :text, metadata: %{}]

  @type t :: %__MODULE__{
          content: String.t(),
          index: non_neg_integer() | nil,
          format: atom(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.AssistantMessage do
  @moduledoc "Represents a completed assistant message."

  use CliSubprocessCore.Payload,
    defaults: [content: [], role: :assistant, model: nil, metadata: %{}]

  @type t :: %__MODULE__{
          content: [term()],
          role: :assistant,
          model: String.t() | nil,
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.UserMessage do
  @moduledoc "Represents normalized user input."

  use CliSubprocessCore.Payload, defaults: [content: [], role: :user, metadata: %{}]

  @type t :: %__MODULE__{
          content: [term()],
          role: :user,
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.Thinking do
  @moduledoc "Represents provider thinking output."

  use CliSubprocessCore.Payload, defaults: [content: "", signature: nil, metadata: %{}]

  @type t :: %__MODULE__{
          content: String.t(),
          signature: String.t() | nil,
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.ToolUse do
  @moduledoc "Represents a tool invocation request."

  use CliSubprocessCore.Payload,
    defaults: [tool_name: nil, tool_call_id: nil, input: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          input: map(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.ToolResult do
  @moduledoc "Represents a tool invocation result."

  use CliSubprocessCore.Payload,
    defaults: [tool_call_id: nil, content: nil, is_error: false, metadata: %{}]

  @type t :: %__MODULE__{
          tool_call_id: String.t() | nil,
          content: term(),
          is_error: boolean(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.ApprovalRequested do
  @moduledoc "Represents an approval request emitted by a provider CLI."

  use CliSubprocessCore.Payload,
    defaults: [approval_id: nil, subject: nil, details: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          subject: String.t() | nil,
          details: map(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.ApprovalResolved do
  @moduledoc "Represents an approval decision."

  use CliSubprocessCore.Payload,
    defaults: [approval_id: nil, decision: nil, reason: nil, metadata: %{}]

  @type decision :: :allow | :deny | atom() | nil
  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          decision: decision(),
          reason: String.t() | nil,
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.CostUpdate do
  @moduledoc "Represents token and cost accounting updates."

  use CliSubprocessCore.Payload,
    defaults: [input_tokens: 0, output_tokens: 0, total_tokens: 0, cost_usd: 0.0, metadata: %{}]

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost_usd: float(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.Result do
  @moduledoc "Represents the terminal result of a provider CLI run."

  use CliSubprocessCore.Payload,
    defaults: [status: nil, stop_reason: nil, output: nil, metadata: %{}]

  @type t :: %__MODULE__{
          status: atom() | nil,
          stop_reason: term(),
          output: term(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.Error do
  @moduledoc "Represents a normalized runtime error."

  use CliSubprocessCore.Payload,
    defaults: [message: "", code: nil, severity: :error, metadata: %{}]

  @type severity :: :info | :warning | :error
  @type t :: %__MODULE__{
          message: String.t(),
          code: String.t() | nil,
          severity: severity(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.Stderr do
  @moduledoc "Represents stderr output emitted by a provider CLI."

  use CliSubprocessCore.Payload, defaults: [content: "", metadata: %{}]

  @type t :: %__MODULE__{
          content: String.t(),
          metadata: map()
        }
end

defmodule CliSubprocessCore.Payload.Raw do
  @moduledoc "Represents an unnormalized raw provider payload."

  use CliSubprocessCore.Payload, defaults: [stream: :stdout, content: nil, metadata: %{}]

  @type stream :: :stdout | :stderr | atom()
  @type t :: %__MODULE__{
          stream: stream(),
          content: term(),
          metadata: map()
        }
end
