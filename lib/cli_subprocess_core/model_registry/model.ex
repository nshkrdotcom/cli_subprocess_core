defmodule CliSubprocessCore.ModelRegistry.Model do
  @moduledoc false

  @type visibility :: :public | :private | :internal | :restricted

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
          metadata: map()
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
            metadata: %{}

  @spec new(atom(), map()) :: {:ok, t()} | {:error, {:model_unavailable, atom(), term()}}
  def new(provider, attrs) when is_atom(provider) and is_map(attrs) do
    with {:ok, id} <- fetch_required(attrs, :id),
         {:ok, aliases} <- parse_aliases(fetch_optional(attrs, :aliases, [])),
         {:ok, visibility} <- parse_visibility(fetch_optional(attrs, :visibility, :public)),
         {:ok, family} <- parse_family(fetch_optional(attrs, :family)),
         {:ok, reasoning_efforts} <-
           parse_reasoning_efforts(fetch_optional(attrs, :reasoning_efforts, %{})),
         {:ok, default_reasoning_effort} <-
           parse_default_reasoning_effort(
             fetch_optional(attrs, :default_reasoning_effort),
             reasoning_efforts
           ),
         {:ok, default_model} <- parse_default_model(fetch_optional(attrs, :default, false)),
         {:ok, catalog_version} <- parse_optional_binary(fetch_optional(attrs, :catalog_version)),
         {:ok, metadata} <- parse_metadata(fetch_optional(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         provider: provider,
         id: id,
         aliases: aliases,
         visibility: visibility,
         family: family,
         default: default_model,
         default_reasoning_effort: default_reasoning_effort,
         reasoning_efforts: reasoning_efforts,
         catalog_version: catalog_version,
         metadata: metadata
       }}
    else
      {:error, reason} ->
        {:error, {:model_unavailable, provider, reason}}
    end
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

  defp fetch_required(attrs, key) do
    value = fetch_optional(attrs, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, {:invalid_model, "missing #{key}"}}
    end
  end

  defp fetch_optional(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp parse_visibility(visibility) when is_atom(visibility) do
    parse_visibility(Atom.to_string(visibility))
  end

  defp parse_visibility(visibility) when is_binary(visibility) do
    case String.downcase(String.trim(visibility)) do
      "public" -> {:ok, :public}
      "private" -> {:ok, :private}
      "internal" -> {:ok, :internal}
      "restricted" -> {:ok, :restricted}
      _ -> {:error, {:invalid_model, "invalid visibility #{inspect(visibility)}"}}
    end
  end

  defp parse_visibility(_other), do: {:error, {:invalid_model, "invalid visibility"}}

  defp parse_aliases(aliases) when is_list(aliases) do
    aliases
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
    |> then(&{:ok, &1})
  end

  defp parse_aliases(_other), do: {:ok, []}

  defp parse_family(nil), do: {:ok, nil}

  defp parse_family(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:ok, nil}
    else
      {:ok, trimmed}
    end
  end

  defp parse_family(_other), do: {:ok, nil}

  defp parse_reasoning_efforts(values) when is_map(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn {key, raw_value}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_reasoning_key(key),
           {:ok, normalized_value} <- normalize_reasoning_value(raw_value) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {:ok, efforts} -> {:ok, efforts}
    end
  end

  defp parse_reasoning_efforts(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn value, {:ok, acc} ->
      if is_binary(value) do
        {:cont, {:ok, Map.put(acc, String.downcase(String.trim(value)), nil)}}
      else
        {:halt, {:error, {:invalid_model, "invalid reasoning effort #{inspect(value)}"}}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {:ok, efforts} -> {:ok, efforts}
    end
  end

  defp parse_reasoning_efforts(_other), do: {:ok, %{}}

  defp normalize_reasoning_key(key) when is_binary(key) do
    normalized = String.trim(key)

    if normalized == "" do
      {:error, {:invalid_model, "invalid reasoning effort key"}}
    else
      {:ok, String.downcase(normalized)}
    end
  end

  defp normalize_reasoning_key(key) when is_atom(key),
    do: normalize_reasoning_key(Atom.to_string(key))

  defp normalize_reasoning_key(_other),
    do: {:error, {:invalid_model, "invalid reasoning effort key"}}

  defp normalize_reasoning_value(value) when is_number(value), do: {:ok, value}
  defp normalize_reasoning_value(nil), do: {:ok, nil}

  defp normalize_reasoning_value(_other),
    do: {:error, {:invalid_model, "invalid reasoning effort value"}}

  defp parse_default_reasoning_effort(nil, _efforts), do: {:ok, nil}

  defp parse_default_reasoning_effort(value, efforts) when is_binary(value) do
    default_reasoning = String.downcase(String.trim(value))

    cond do
      default_reasoning == "" ->
        {:ok, nil}

      Map.has_key?(efforts, default_reasoning) ->
        {:ok, default_reasoning}

      true ->
        {:error,
         {:invalid_model, "unknown default reasoning effort #{inspect(default_reasoning)}"}}
    end
  end

  defp parse_default_reasoning_effort(value, efforts) when is_atom(value) do
    parse_default_reasoning_effort(Atom.to_string(value), efforts)
  end

  defp parse_default_reasoning_effort(_value, _efforts), do: {:ok, nil}

  defp parse_default_model(value) when is_boolean(value), do: {:ok, value}
  defp parse_default_model(_other), do: {:ok, false}

  defp parse_optional_binary(nil), do: {:ok, nil}

  defp parse_optional_binary(value) when is_binary(value) do
    value = String.trim(value)
    {:ok, if(value == "", do: nil, else: value)}
  end

  defp parse_optional_binary(_other), do: {:ok, nil}

  defp parse_metadata(value) when is_map(value), do: {:ok, value}
  defp parse_metadata(_other), do: {:ok, %{}}
end
