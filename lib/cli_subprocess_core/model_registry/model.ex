defmodule CliSubprocessCore.ModelRegistry.Model do
  @moduledoc """
  Canonical model metadata loaded by `CliSubprocessCore.ModelRegistry`.
  """

  alias CliSubprocessCore.Schema
  alias CliSubprocessCore.Schema.Conventions

  @type visibility :: :public | :private | :internal | :restricted

  @known_fields [
    :provider,
    :id,
    :aliases,
    :visibility,
    :family,
    :default,
    :default_reasoning_effort,
    :reasoning_efforts,
    :catalog_version,
    :metadata
  ]

  @reasoning_efforts_schema Zoi.default(
                              Zoi.optional(
                                Zoi.nullish(
                                  Zoi.union([
                                    Zoi.map(
                                      Zoi.union([Zoi.string(), Zoi.atom()]),
                                      Zoi.nullish(Zoi.number())
                                    ),
                                    Zoi.array(Zoi.string())
                                  ])
                                )
                              ),
                              %{}
                            )

  @schema Zoi.map(
            %{
              provider: Zoi.atom(),
              id: Conventions.trimmed_string() |> Zoi.min(1),
              aliases: Zoi.default(Zoi.optional(Zoi.array(Zoi.any())), []),
              visibility:
                Conventions.default_enum([:public, :private, :internal, :restricted], :public),
              family: Conventions.optional_trimmed_string(),
              default: Zoi.default(Zoi.optional(Zoi.boolean()), false),
              default_reasoning_effort:
                Zoi.optional(Zoi.nullish(Zoi.union([Zoi.string(), Zoi.atom()]))),
              reasoning_efforts: @reasoning_efforts_schema,
              catalog_version: Conventions.optional_trimmed_string(),
              metadata: Conventions.metadata()
            },
            coerce: true,
            unrecognized_keys: :preserve
          )

  @type t :: %__MODULE__{
          provider: atom(),
          id: String.t(),
          aliases: [String.t()],
          visibility: visibility(),
          family: String.t() | nil,
          default: boolean(),
          default_reasoning_effort: String.t() | nil,
          reasoning_efforts: %{String.t() => number() | nil},
          catalog_version: String.t() | nil,
          metadata: map(),
          extra: map()
        }

  defstruct provider: nil,
            id: nil,
            aliases: [],
            visibility: :public,
            family: nil,
            default: false,
            default_reasoning_effort: nil,
            reasoning_efforts: %{},
            catalog_version: nil,
            metadata: %{},
            extra: %{}

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec parse(atom(), keyword() | map()) ::
          {:ok, t()} | {:error, {:model_unavailable, atom(), term()}}
  def parse(provider, attrs) when is_atom(provider) and (is_list(attrs) or is_map(attrs)) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:provider, provider)

    with {:ok, parsed} <- Schema.parse(@schema, attrs, :invalid_model),
         {:ok, aliases} <- normalize_aliases(Map.get(parsed, :aliases, [])),
         {:ok, reasoning_efforts} <-
           normalize_reasoning_efforts(Map.get(parsed, :reasoning_efforts, %{})),
         {:ok, default_reasoning_effort} <-
           normalize_default_reasoning_effort(
             Map.get(parsed, :default_reasoning_effort),
             reasoning_efforts
           ) do
      {known, extra} = Schema.split_extra(parsed, @known_fields)

      {:ok,
       %__MODULE__{
         provider: provider,
         id: Map.fetch!(known, :id),
         aliases: aliases,
         visibility: Map.get(known, :visibility, :public),
         family: blank_to_nil(Map.get(known, :family)),
         default: Map.get(known, :default, false),
         default_reasoning_effort: default_reasoning_effort,
         reasoning_efforts: reasoning_efforts,
         catalog_version: blank_to_nil(Map.get(known, :catalog_version)),
         metadata: Map.get(known, :metadata, %{}),
         extra: extra
       }}
    else
      {:error, {:invalid_model, details}} ->
        {:error, {:model_unavailable, provider, {:invalid_model, "invalid model", details}}}

      {:error, reason} ->
        {:error, {:model_unavailable, provider, {:invalid_model, "invalid model", reason}}}
    end
  end

  @spec new(atom(), map()) :: {:ok, t()} | {:error, {:model_unavailable, atom(), term()}}
  def new(provider, attrs) when is_atom(provider) and is_map(attrs) do
    parse(provider, attrs)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Schema.to_map(model, @known_fields)
  end

  @spec matches_id_or_alias?(t(), String.t()) :: boolean()
  def matches_id_or_alias?(%__MODULE__{} = model, requested) when is_binary(requested) do
    normalized = String.trim(requested)

    model.id == normalized or Enum.member?(model.aliases, normalized)
  end

  @spec resolve_id(t(), String.t()) :: {:ok, String.t()} | :error
  def resolve_id(%__MODULE__{id: id, aliases: aliases}, requested) when is_binary(requested) do
    normalized = String.trim(requested)

    cond do
      id == normalized -> {:ok, id}
      normalized in aliases -> {:ok, id}
      true -> :error
    end
  end

  defp normalize_aliases(aliases) when is_list(aliases) do
    aliases
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
    |> then(&{:ok, &1})
  end

  defp normalize_aliases(_other), do: {:error, {:aliases, "must be a list"}}

  defp normalize_reasoning_efforts(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, raw_value}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_reasoning_key(key),
           {:ok, normalized_value} <- normalize_reasoning_value(raw_value) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_reasoning_efforts(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      if is_binary(value) do
        normalized = value |> String.trim() |> String.downcase()

        if normalized == "" do
          {:halt, {:error, {:reasoning_efforts, "keys must not be blank"}}}
        else
          {:cont, {:ok, Map.put(acc, normalized, nil)}}
        end
      else
        {:halt, {:error, {:reasoning_efforts, "list values must be strings"}}}
      end
    end)
  end

  defp normalize_reasoning_efforts(_other),
    do: {:error, {:reasoning_efforts, "must be a map or list"}}

  defp normalize_reasoning_key(key) when is_binary(key) do
    normalized = key |> String.trim() |> String.downcase()

    if normalized == "" do
      {:error, {:reasoning_efforts, "keys must not be blank"}}
    else
      {:ok, normalized}
    end
  end

  defp normalize_reasoning_key(key) when is_atom(key),
    do: normalize_reasoning_key(Atom.to_string(key))

  defp normalize_reasoning_key(_other),
    do: {:error, {:reasoning_efforts, "keys must be atoms or strings"}}

  defp normalize_reasoning_value(value) when is_number(value), do: {:ok, value}
  defp normalize_reasoning_value(nil), do: {:ok, nil}

  defp normalize_reasoning_value(_other),
    do: {:error, {:reasoning_efforts, "values must be numbers or nil"}}

  defp normalize_default_reasoning_effort(nil, _efforts), do: {:ok, nil}

  defp normalize_default_reasoning_effort(value, efforts) when is_atom(value) do
    normalize_default_reasoning_effort(Atom.to_string(value), efforts)
  end

  defp normalize_default_reasoning_effort(value, efforts) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:ok, nil}

      Map.has_key?(efforts, normalized) ->
        {:ok, normalized}

      true ->
        {:error, {:default_reasoning_effort, "must reference a declared reasoning effort"}}
    end
  end

  defp normalize_default_reasoning_effort(_value, _efforts) do
    {:error, {:default_reasoning_effort, "must be a string, atom, or nil"}}
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
