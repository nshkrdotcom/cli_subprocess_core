defmodule CliSubprocessCore.Payload do
  @moduledoc """
  Namespace for the normalized runtime payload structs emitted by the core.
  """

  @doc false
  defmacro __using__(defaults: defaults, schema_fields: schema_fields) do
    known_fields = defaults |> Keyword.keys() |> Macro.escape()
    defaults = Keyword.put_new(defaults, :extra, %{}) |> Macro.escape()

    quote do
      @known_fields unquote(known_fields)
      @schema Zoi.map(unquote(schema_fields), coerce: true, unrecognized_keys: :preserve)

      defstruct unquote(defaults)

      @spec schema() :: Zoi.schema()
      def schema, do: @schema

      @spec parse(keyword() | map() | struct()) ::
              {:ok, struct()}
              | {:error, {:invalid_payload, module(), CliSubprocessCore.Schema.error_detail()}}
      def parse(%__MODULE__{} = payload), do: {:ok, payload}
      def parse(attrs) when is_list(attrs), do: parse(Enum.into(attrs, %{}))

      def parse(attrs) do
        case CliSubprocessCore.Schema.parse(@schema, attrs, :invalid_payload) do
          {:ok, parsed} ->
            {:ok, build_struct(parsed)}

          {:error, {:invalid_payload, details}} ->
            {:error, {:invalid_payload, __MODULE__, details}}
        end
      end

      @spec parse!(keyword() | map() | struct()) :: struct()
      def parse!(%__MODULE__{} = payload), do: payload
      def parse!(attrs) when is_list(attrs), do: parse!(Enum.into(attrs, %{}))

      def parse!(attrs) do
        CliSubprocessCore.Schema.parse!(@schema, attrs, {:invalid_payload, __MODULE__})
        |> build_struct()
      end

      @spec new(keyword() | map() | struct()) :: struct()
      def new(attrs \\ []), do: parse!(attrs)

      @spec to_map(struct()) :: map()
      def to_map(%__MODULE__{} = payload) do
        CliSubprocessCore.Schema.to_map(payload, @known_fields)
      end

      defp build_struct(parsed) do
        {known, extra} = CliSubprocessCore.Schema.split_extra(parsed, @known_fields)
        struct(__MODULE__, Map.put(known, :extra, extra))
      end
    end
  end

  @doc false
  @spec normalize_metadata(term()) :: map()
  def normalize_metadata(metadata) when is_map(metadata), do: metadata
  def normalize_metadata(_metadata), do: %{}

  @doc false
  @spec content_list_schema() :: Zoi.schema()
  def content_list_schema do
    Zoi.default(Zoi.optional(Zoi.array(Zoi.any())), [])
  end

  @doc false
  @spec optional_non_neg_integer_schema() :: Zoi.schema()
  def optional_non_neg_integer_schema do
    Zoi.optional(Zoi.nullish(Zoi.integer(gte: 0)))
  end

  @doc false
  @spec non_neg_integer_schema(non_neg_integer()) :: Zoi.schema()
  def non_neg_integer_schema(default) when is_integer(default) and default >= 0 do
    Zoi.default(optional_non_neg_integer_schema(), default)
  end

  @doc false
  @spec non_neg_number_schema(number()) :: Zoi.schema()
  def non_neg_number_schema(default) when is_number(default) and default >= 0 do
    Zoi.default(Zoi.optional(Zoi.nullish(Zoi.number(gte: 0))), default)
  end
end

defmodule CliSubprocessCore.Payload.RunStarted do
  @moduledoc "Marks the start of a provider CLI run."

  use CliSubprocessCore.Payload,
    defaults: [
      provider_session_id: nil,
      command: nil,
      args: [],
      cwd: nil,
      metadata: %{}
    ],
    schema_fields: %{
      provider_session_id: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      command: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      args: CliSubprocessCore.Schema.Conventions.string_list(),
      cwd: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          provider_session_id: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          cwd: String.t() | nil,
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.AssistantDelta do
  @moduledoc "Represents a streamed assistant delta."

  use CliSubprocessCore.Payload,
    defaults: [content: "", index: nil, format: :text, metadata: %{}],
    schema_fields: %{
      content: CliSubprocessCore.Schema.Conventions.default_trimmed_string(""),
      index: CliSubprocessCore.Payload.optional_non_neg_integer_schema(),
      format: CliSubprocessCore.Schema.Conventions.default_any(:text),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          content: String.t(),
          index: non_neg_integer() | nil,
          format: term(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.AssistantMessage do
  @moduledoc "Represents a completed assistant message."

  use CliSubprocessCore.Payload,
    defaults: [content: [], role: :assistant, model: nil, metadata: %{}],
    schema_fields: %{
      content: CliSubprocessCore.Payload.content_list_schema(),
      role: CliSubprocessCore.Schema.Conventions.default_enum([:assistant], :assistant),
      model: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          content: [term()],
          role: :assistant,
          model: String.t() | nil,
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.UserMessage do
  @moduledoc "Represents normalized user input."

  use CliSubprocessCore.Payload,
    defaults: [content: [], role: :user, metadata: %{}],
    schema_fields: %{
      content: CliSubprocessCore.Payload.content_list_schema(),
      role: CliSubprocessCore.Schema.Conventions.default_enum([:user], :user),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          content: [term()],
          role: :user,
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.Thinking do
  @moduledoc "Represents provider thinking output."

  use CliSubprocessCore.Payload,
    defaults: [content: "", signature: nil, metadata: %{}],
    schema_fields: %{
      content: CliSubprocessCore.Schema.Conventions.default_trimmed_string(""),
      signature: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          content: String.t(),
          signature: String.t() | nil,
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.ToolUse do
  @moduledoc "Represents a tool invocation request."

  use CliSubprocessCore.Payload,
    defaults: [tool_name: nil, tool_call_id: nil, input: %{}, metadata: %{}],
    schema_fields: %{
      tool_name: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      tool_call_id: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      input: CliSubprocessCore.Schema.Conventions.default_map(%{}),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          input: map(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.ToolResult do
  @moduledoc "Represents a tool invocation result."

  use CliSubprocessCore.Payload,
    defaults: [tool_call_id: nil, content: nil, is_error: false, metadata: %{}],
    schema_fields: %{
      tool_call_id: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      content: CliSubprocessCore.Schema.Conventions.optional_any(),
      is_error: Zoi.default(Zoi.optional(Zoi.boolean()), false),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          tool_call_id: String.t() | nil,
          content: term(),
          is_error: boolean(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.ApprovalRequested do
  @moduledoc "Represents an approval request emitted by a provider CLI."

  use CliSubprocessCore.Payload,
    defaults: [approval_id: nil, subject: nil, details: %{}, metadata: %{}],
    schema_fields: %{
      approval_id: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      subject: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      details: CliSubprocessCore.Schema.Conventions.default_map(%{}),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          subject: String.t() | nil,
          details: map(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.ApprovalResolved do
  @moduledoc "Represents an approval decision."

  use CliSubprocessCore.Payload,
    defaults: [approval_id: nil, decision: nil, reason: nil, metadata: %{}],
    schema_fields: %{
      approval_id: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      decision: CliSubprocessCore.Schema.Conventions.optional_any(),
      reason: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type decision :: :allow | :deny | atom() | String.t() | nil
  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          decision: decision(),
          reason: String.t() | nil,
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.CostUpdate do
  @moduledoc "Represents token and cost accounting updates."

  use CliSubprocessCore.Payload,
    defaults: [input_tokens: 0, output_tokens: 0, total_tokens: 0, cost_usd: 0.0, metadata: %{}],
    schema_fields: %{
      input_tokens: CliSubprocessCore.Payload.non_neg_integer_schema(0),
      output_tokens: CliSubprocessCore.Payload.non_neg_integer_schema(0),
      total_tokens: CliSubprocessCore.Payload.non_neg_integer_schema(0),
      cost_usd: CliSubprocessCore.Payload.non_neg_number_schema(0.0),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost_usd: number(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.Result do
  @moduledoc "Represents the terminal result of a provider CLI run."

  use CliSubprocessCore.Payload,
    defaults: [status: nil, stop_reason: nil, output: nil, metadata: %{}],
    schema_fields: %{
      status: CliSubprocessCore.Schema.Conventions.optional_any(),
      stop_reason: CliSubprocessCore.Schema.Conventions.optional_any(),
      output: CliSubprocessCore.Schema.Conventions.optional_any(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          status: term(),
          stop_reason: term(),
          output: term(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.Error do
  @moduledoc "Represents a normalized runtime error."

  use CliSubprocessCore.Payload,
    defaults: [message: "", code: nil, severity: :error, metadata: %{}],
    schema_fields: %{
      message: CliSubprocessCore.Schema.Conventions.default_trimmed_string(""),
      code: CliSubprocessCore.Schema.Conventions.optional_trimmed_string(),
      severity:
        CliSubprocessCore.Schema.Conventions.default_enum([:info, :warning, :error], :error),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type severity :: :info | :warning | :error
  @type t :: %__MODULE__{
          message: String.t(),
          code: String.t() | nil,
          severity: severity(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.Stderr do
  @moduledoc "Represents stderr output emitted by a provider CLI."

  use CliSubprocessCore.Payload,
    defaults: [content: "", metadata: %{}],
    schema_fields: %{
      content: CliSubprocessCore.Schema.Conventions.default_trimmed_string(""),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type t :: %__MODULE__{
          content: String.t(),
          metadata: map(),
          extra: map()
        }
end

defmodule CliSubprocessCore.Payload.Raw do
  @moduledoc "Represents an unnormalized raw provider payload."

  use CliSubprocessCore.Payload,
    defaults: [stream: :stdout, content: nil, metadata: %{}],
    schema_fields: %{
      stream: CliSubprocessCore.Schema.Conventions.default_any(:stdout),
      content: CliSubprocessCore.Schema.Conventions.optional_any(),
      metadata: CliSubprocessCore.Schema.Conventions.metadata()
    }

  @type stream :: :stdout | :stderr | atom() | String.t()
  @type t :: %__MODULE__{
          stream: stream(),
          content: term(),
          metadata: map(),
          extra: map()
        }
end
