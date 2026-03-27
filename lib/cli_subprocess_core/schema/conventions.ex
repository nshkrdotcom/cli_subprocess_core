defmodule CliSubprocessCore.Schema.Conventions do
  @moduledoc false

  @type enum_value :: atom() | String.t()

  @spec any_map() :: Zoi.schema()
  def any_map, do: Zoi.map(Zoi.any(), Zoi.any())

  @spec metadata() :: Zoi.schema()
  def metadata, do: default_map(%{})

  @spec default_map(map()) :: Zoi.schema()
  def default_map(default) when is_map(default) do
    Zoi.default(optional_map(), default)
  end

  @spec optional_map() :: Zoi.schema()
  def optional_map, do: Zoi.optional(Zoi.nullish(any_map()))

  @spec trimmed_string() :: Zoi.schema()
  def trimmed_string do
    Zoi.string()
    |> Zoi.trim()
  end

  @spec optional_trimmed_string() :: Zoi.schema()
  def optional_trimmed_string, do: Zoi.optional(Zoi.nullish(trimmed_string()))

  @spec default_trimmed_string(String.t()) :: Zoi.schema()
  def default_trimmed_string(default) when is_binary(default) do
    Zoi.default(optional_trimmed_string(), default)
  end

  @spec string_list([String.t()]) :: Zoi.schema()
  def string_list(default \\ []) when is_list(default) do
    Zoi.default(Zoi.optional(Zoi.nullish(Zoi.array(trimmed_string()))), default)
  end

  @spec default_any(term()) :: Zoi.schema()
  def default_any(default), do: Zoi.default(optional_any(), default)

  @spec optional_any() :: Zoi.schema()
  def optional_any, do: Zoi.optional(Zoi.nullish(Zoi.any()))

  @spec enum([atom()]) :: Zoi.schema()
  def enum(values) when is_list(values) do
    Zoi.any()
    |> Zoi.transform({__MODULE__, :normalize_enum, [values]})
  end

  @spec optional_enum([atom()]) :: Zoi.schema()
  def optional_enum(values), do: Zoi.optional(Zoi.nullish(enum(values)))

  @spec default_enum([atom()], atom()) :: Zoi.schema()
  def default_enum(values, default) when is_atom(default) do
    Zoi.default(optional_enum(values), default)
  end

  @spec normalize_enum(enum_value(), [atom()], keyword()) :: {:ok, atom()} | {:error, String.t()}
  def normalize_enum(value, values, _opts) do
    case find_enum_value(value, values) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error, "expected one of #{Enum.map_join(values, ", ", &inspect/1)}"}
    end
  end

  defp find_enum_value(value, values) when is_atom(value) do
    if value in values, do: {:ok, value}, else: :error
  end

  defp find_enum_value(value, values) when is_binary(value) do
    normalized = String.trim(value)

    Enum.find_value(values, :error, fn candidate ->
      if Atom.to_string(candidate) == normalized, do: {:ok, candidate}
    end)
  end

  defp find_enum_value(_value, _values), do: :error
end
