defmodule CliSubprocessCore.Tool do
  @moduledoc """
  Neutral, serializable tool data used by the common CLI runtime.

  These structs describe tool contracts and tool exchange data. They do not
  execute tools, store callbacks, dispatch MCP requests, or render provider
  configuration. Provider SDKs own provider-native tool registration and
  rendering.
  """

  @type json_scalar :: nil | boolean() | number() | String.t()
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}

  @type validation_error :: %{path: [String.t()], reason: atom(), type: atom()}

  @doc false
  @spec normalize_attrs(keyword() | map() | struct()) :: map()
  def normalize_attrs(%module{} = struct) when module != __MODULE__, do: Map.from_struct(struct)
  def normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  def normalize_attrs(%{} = attrs), do: attrs

  @doc false
  @spec fetch_field(map(), atom(), term()) :: term()
  def fetch_field(attrs, field, default) when is_atom(field) do
    Map.get_lazy(attrs, field, fn -> Map.get(attrs, Atom.to_string(field), default) end)
  end

  @doc false
  @spec validate_required_string(term(), atom()) ::
          {:ok, String.t()} | {:error, validation_error()}
  def validate_required_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error([Atom.to_string(field)], :required, :empty_string)}
      trimmed -> {:ok, trimmed}
    end
  end

  def validate_required_string(_value, field) do
    {:error, error([Atom.to_string(field)], :required, :invalid_string)}
  end

  @doc false
  @spec validate_optional_string(term(), atom()) ::
          {:ok, String.t() | nil} | {:error, validation_error()}
  def validate_optional_string(nil, _field), do: {:ok, nil}

  def validate_optional_string(value, _field) when is_binary(value) do
    {:ok, String.trim(value)}
  end

  def validate_optional_string(_value, field) do
    {:error, error([Atom.to_string(field)], :optional_string, :invalid_string)}
  end

  @doc false
  @spec validate_serializable(term(), [String.t()]) :: :ok | {:error, validation_error()}
  def validate_serializable(value, path \\ []) do
    cond do
      is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) ->
        :ok

      is_list(value) ->
        validate_serializable_list(value, path, 0)

      is_map(value) and not is_struct(value) ->
        validate_serializable_map(value, path)

      true ->
        {:error, error(path, :serializable, unsupported_type(value))}
    end
  end

  @doc false
  @spec require_serializable_map(term(), atom()) :: {:ok, map()} | {:error, validation_error()}
  def require_serializable_map(value, field) when is_map(value) and not is_struct(value) do
    case validate_serializable(value, [Atom.to_string(field)]) do
      :ok -> {:ok, value}
      {:error, error} -> {:error, error}
    end
  end

  def require_serializable_map(_value, field) do
    {:error, error([Atom.to_string(field)], :serializable_map, :invalid_map)}
  end

  @doc false
  @spec optional_serializable_map(term(), atom()) ::
          {:ok, map() | nil} | {:error, validation_error()}
  def optional_serializable_map(nil, _field), do: {:ok, nil}
  def optional_serializable_map(value, field), do: require_serializable_map(value, field)

  @doc false
  @spec split_extra(map(), [atom()]) :: {map(), map()}
  def split_extra(attrs, known_fields) do
    {known, extra} =
      Enum.reduce(attrs, {%{}, %{}}, fn {key, value}, {known, extra} ->
        case known_field(key, known_fields) do
          {:ok, field} -> {Map.put_new(known, field, value), extra}
          :error -> {known, Map.put(extra, key, value)}
        end
      end)

    {known, extra}
  end

  @doc false
  @spec error([String.t()], atom(), atom()) :: validation_error()
  def error(path, reason, type), do: %{path: path, reason: reason, type: type}

  @doc false
  @spec raise_invalid(module(), [validation_error()]) :: no_return()
  def raise_invalid(module, errors) do
    raise ArgumentError, "invalid #{inspect(module)}: #{inspect(errors)}"
  end

  defp validate_serializable_list([], _path, _index), do: :ok

  defp validate_serializable_list([value | rest], path, index) do
    case validate_serializable(value, path ++ [Integer.to_string(index)]) do
      :ok -> validate_serializable_list(rest, path, index + 1)
      {:error, error} -> {:error, error}
    end
  end

  defp validate_serializable_map(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      validate_serializable_map_entry(key, value, path)
    end)
  end

  defp validate_serializable_map_entry(key, value, path) when is_binary(key) do
    case validate_serializable(value, path ++ [key]) do
      :ok -> {:cont, :ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp validate_serializable_map_entry(key, _value, path) do
    {:halt, {:error, error(path ++ [inspect(key)], :serializable_key, unsupported_type(key))}}
  end

  defp unsupported_type(value) do
    cond do
      is_function(value) -> :function
      is_pid(value) -> :pid
      is_port(value) -> :port
      is_reference(value) -> :reference
      is_tuple(value) -> :tuple
      is_atom(value) -> :atom
      is_struct(value) -> :struct
      true -> :term
    end
  end

  defp known_field(field, known_fields) when is_atom(field) do
    if field in known_fields, do: {:ok, field}, else: :error
  end

  defp known_field(field, known_fields) when is_binary(field) do
    Enum.find_value(known_fields, :error, fn known_field ->
      if Atom.to_string(known_field) == field, do: {:ok, known_field}
    end)
  end

  defp known_field(_field, _known_fields), do: :error
end

defmodule CliSubprocessCore.Tool.Descriptor do
  @moduledoc """
  Serializable description of a tool contract.
  """

  alias CliSubprocessCore.Tool

  @known_fields [:name, :description, :input_schema, :output_schema, :provider_metadata]

  defstruct name: nil,
            description: nil,
            input_schema: %{},
            output_schema: nil,
            provider_metadata: %{},
            extra: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: Tool.json_value(),
          output_schema: Tool.json_value() | nil,
          provider_metadata: %{optional(String.t()) => Tool.json_value()},
          extra: map()
        }

  @spec parse(keyword() | map() | t()) ::
          {:ok, t()} | {:error, {:invalid_tool, module(), [Tool.validation_error()]}}
  def parse(%__MODULE__{} = descriptor), do: {:ok, descriptor}

  def parse(attrs) do
    attrs = Tool.normalize_attrs(attrs)
    {known, extra} = Tool.split_extra(attrs, @known_fields)

    with {:ok, name} <- Tool.validate_required_string(Tool.fetch_field(known, :name, nil), :name),
         {:ok, description} <-
           Tool.validate_optional_string(Tool.fetch_field(known, :description, nil), :description),
         {:ok, input_schema} <-
           Tool.require_serializable_map(
             Tool.fetch_field(known, :input_schema, %{}),
             :input_schema
           ),
         {:ok, output_schema} <-
           Tool.optional_serializable_map(
             Tool.fetch_field(known, :output_schema, nil),
             :output_schema
           ),
         {:ok, provider_metadata} <-
           Tool.require_serializable_map(
             Tool.fetch_field(known, :provider_metadata, %{}),
             :provider_metadata
           ),
         :ok <- Tool.validate_serializable(extra, ["extra"]) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         input_schema: input_schema,
         output_schema: output_schema,
         provider_metadata: provider_metadata,
         extra: extra
       }}
    else
      {:error, error} -> {:error, {:invalid_tool, __MODULE__, [error]}}
    end
  end

  @spec parse!(keyword() | map() | t()) :: t()
  def parse!(attrs) do
    case parse(attrs) do
      {:ok, descriptor} -> descriptor
      {:error, {:invalid_tool, module, errors}} -> Tool.raise_invalid(module, errors)
    end
  end

  @spec new(keyword() | map() | t()) :: t()
  def new(attrs \\ []), do: parse!(attrs)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = descriptor) do
    descriptor
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.merge(descriptor.extra)
  end
end

defmodule CliSubprocessCore.Tool.Request do
  @moduledoc """
  Serializable tool request data normalized by the core.
  """

  alias CliSubprocessCore.Tool

  @known_fields [:tool_name, :tool_call_id, :input, :provider_metadata]

  defstruct tool_name: nil,
            tool_call_id: nil,
            input: %{},
            provider_metadata: %{},
            extra: %{}

  @type t :: %__MODULE__{
          tool_name: String.t(),
          tool_call_id: String.t(),
          input: %{optional(String.t()) => Tool.json_value()},
          provider_metadata: %{optional(String.t()) => Tool.json_value()},
          extra: map()
        }

  @spec parse(keyword() | map() | t()) ::
          {:ok, t()} | {:error, {:invalid_tool, module(), [Tool.validation_error()]}}
  def parse(%__MODULE__{} = request), do: {:ok, request}

  def parse(attrs) do
    attrs = Tool.normalize_attrs(attrs)
    {known, extra} = Tool.split_extra(attrs, @known_fields)

    with {:ok, tool_name} <-
           Tool.validate_required_string(Tool.fetch_field(known, :tool_name, nil), :tool_name),
         {:ok, tool_call_id} <-
           Tool.validate_required_string(
             Tool.fetch_field(known, :tool_call_id, nil),
             :tool_call_id
           ),
         {:ok, input} <-
           Tool.require_serializable_map(Tool.fetch_field(known, :input, %{}), :input),
         {:ok, provider_metadata} <-
           Tool.require_serializable_map(
             Tool.fetch_field(known, :provider_metadata, %{}),
             :provider_metadata
           ),
         :ok <- Tool.validate_serializable(extra, ["extra"]) do
      {:ok,
       %__MODULE__{
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         input: input,
         provider_metadata: provider_metadata,
         extra: extra
       }}
    else
      {:error, error} -> {:error, {:invalid_tool, __MODULE__, [error]}}
    end
  end

  @spec parse!(keyword() | map() | t()) :: t()
  def parse!(attrs) do
    case parse(attrs) do
      {:ok, request} -> request
      {:error, {:invalid_tool, module, errors}} -> Tool.raise_invalid(module, errors)
    end
  end

  @spec new(keyword() | map() | t()) :: t()
  def new(attrs \\ []), do: parse!(attrs)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    request
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.merge(request.extra)
  end
end

defmodule CliSubprocessCore.Tool.Response do
  @moduledoc """
  Serializable tool response data normalized by the core.
  """

  alias CliSubprocessCore.Tool

  @known_fields [:tool_call_id, :content, :is_error, :provider_metadata]

  defstruct tool_call_id: nil,
            content: nil,
            is_error: false,
            provider_metadata: %{},
            extra: %{}

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          content: Tool.json_value(),
          is_error: boolean(),
          provider_metadata: %{optional(String.t()) => Tool.json_value()},
          extra: map()
        }

  @spec parse(keyword() | map() | t()) ::
          {:ok, t()} | {:error, {:invalid_tool, module(), [Tool.validation_error()]}}
  def parse(%__MODULE__{} = response), do: {:ok, response}

  def parse(attrs) do
    attrs = Tool.normalize_attrs(attrs)
    {known, extra} = Tool.split_extra(attrs, @known_fields)

    with {:ok, tool_call_id} <-
           Tool.validate_required_string(
             Tool.fetch_field(known, :tool_call_id, nil),
             :tool_call_id
           ),
         :ok <- Tool.validate_serializable(Tool.fetch_field(known, :content, nil), ["content"]),
         {:ok, is_error} <- validate_is_error(Tool.fetch_field(known, :is_error, false)),
         {:ok, provider_metadata} <-
           Tool.require_serializable_map(
             Tool.fetch_field(known, :provider_metadata, %{}),
             :provider_metadata
           ),
         :ok <- Tool.validate_serializable(extra, ["extra"]) do
      {:ok,
       %__MODULE__{
         tool_call_id: tool_call_id,
         content: Tool.fetch_field(known, :content, nil),
         is_error: is_error,
         provider_metadata: provider_metadata,
         extra: extra
       }}
    else
      {:error, error} -> {:error, {:invalid_tool, __MODULE__, [error]}}
    end
  end

  @spec parse!(keyword() | map() | t()) :: t()
  def parse!(attrs) do
    case parse(attrs) do
      {:ok, response} -> response
      {:error, {:invalid_tool, module, errors}} -> Tool.raise_invalid(module, errors)
    end
  end

  @spec new(keyword() | map() | t()) :: t()
  def new(attrs \\ []), do: parse!(attrs)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    response
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.merge(response.extra)
  end

  defp validate_is_error(value) when is_boolean(value), do: {:ok, value}

  defp validate_is_error(_value) do
    {:error, Tool.error(["is_error"], :boolean, :invalid_boolean)}
  end
end
