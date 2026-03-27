defmodule CliSubprocessCore.ModelRegistry.Selection do
  @moduledoc """
  Resolved model selection returned by `CliSubprocessCore.ModelRegistry`.
  """

  alias CliSubprocessCore.Schema
  alias CliSubprocessCore.Schema.Conventions

  @type resolution_source :: :explicit | :env | :default | :remote
  @type model_source :: :catalog | :external

  @known_fields [
    :provider,
    :requested_model,
    :resolved_model,
    :resolution_source,
    :reasoning,
    :reasoning_effort,
    :normalized_reasoning_effort,
    :model_family,
    :catalog_version,
    :visibility,
    :provider_backend,
    :model_source,
    :env_overrides,
    :settings_patch,
    :backend_metadata,
    :errors
  ]

  @schema Zoi.map(
            %{
              provider: Zoi.optional(Zoi.nullish(Zoi.atom())),
              requested_model: Conventions.optional_trimmed_string(),
              resolved_model: Conventions.optional_trimmed_string(),
              resolution_source: Conventions.optional_enum([:explicit, :env, :default, :remote]),
              reasoning: Conventions.optional_trimmed_string(),
              reasoning_effort: Zoi.optional(Zoi.nullish(Zoi.number())),
              normalized_reasoning_effort: Zoi.optional(Zoi.nullish(Zoi.number())),
              model_family: Conventions.optional_trimmed_string(),
              catalog_version: Conventions.optional_trimmed_string(),
              visibility:
                Conventions.default_enum([:public, :private, :internal, :restricted], :public),
              provider_backend: Zoi.optional(Zoi.nullish(Zoi.atom())),
              model_source: Conventions.default_enum([:catalog, :external], :catalog),
              env_overrides: Conventions.default_map(%{}),
              settings_patch: Conventions.default_map(%{}),
              backend_metadata: Conventions.default_map(%{}),
              errors: Zoi.default(Zoi.optional(Zoi.array(Zoi.any())), [])
            },
            coerce: true,
            unrecognized_keys: :preserve
          )

  @type t :: %__MODULE__{
          provider: atom(),
          requested_model: String.t() | nil,
          resolved_model: String.t() | nil,
          resolution_source: resolution_source() | nil,
          reasoning: String.t() | nil,
          reasoning_effort: number() | nil,
          normalized_reasoning_effort: number() | nil,
          model_family: String.t() | nil,
          catalog_version: String.t() | nil,
          visibility: :public | :private | :internal | :restricted,
          provider_backend: atom() | nil,
          model_source: model_source(),
          env_overrides: map(),
          settings_patch: map(),
          backend_metadata: map(),
          errors: [term()],
          extra: map()
        }

  defstruct provider: nil,
            requested_model: nil,
            resolved_model: nil,
            resolution_source: nil,
            reasoning: nil,
            reasoning_effort: nil,
            normalized_reasoning_effort: nil,
            model_family: nil,
            catalog_version: nil,
            visibility: :public,
            provider_backend: nil,
            model_source: :catalog,
            env_overrides: %{},
            settings_patch: %{},
            backend_metadata: %{},
            errors: [],
            extra: %{}

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec parse(keyword() | map() | t()) ::
          {:ok, t()} | {:error, {:invalid_selection, CliSubprocessCore.Schema.error_detail()}}
  def parse(%__MODULE__{} = selection), do: {:ok, selection}
  def parse(attrs) when is_list(attrs), do: parse(Enum.into(attrs, %{}))

  def parse(attrs) do
    case Schema.parse(@schema, attrs, :invalid_selection) do
      {:ok, parsed} ->
        {known, extra} = Schema.split_extra(parsed, @known_fields)

        {:ok,
         %__MODULE__{
           provider: Map.get(known, :provider),
           requested_model: blank_to_nil(Map.get(known, :requested_model)),
           resolved_model: blank_to_nil(Map.get(known, :resolved_model)),
           resolution_source: Map.get(known, :resolution_source),
           reasoning: blank_to_nil(Map.get(known, :reasoning)),
           reasoning_effort: Map.get(known, :reasoning_effort),
           normalized_reasoning_effort: Map.get(known, :normalized_reasoning_effort),
           model_family: blank_to_nil(Map.get(known, :model_family)),
           catalog_version: blank_to_nil(Map.get(known, :catalog_version)),
           visibility: Map.get(known, :visibility, :public),
           provider_backend: Map.get(known, :provider_backend),
           model_source: Map.get(known, :model_source, :catalog),
           env_overrides: Map.get(known, :env_overrides, %{}),
           settings_patch: Map.get(known, :settings_patch, %{}),
           backend_metadata: Map.get(known, :backend_metadata, %{}),
           errors: Map.get(known, :errors, []),
           extra: extra
         }}

      {:error, {:invalid_selection, details}} ->
        {:error, {:invalid_selection, details}}
    end
  end

  @spec parse!(keyword() | map() | t()) :: t()
  def parse!(%__MODULE__{} = selection), do: selection
  def parse!(attrs) when is_list(attrs), do: parse!(Enum.into(attrs, %{}))

  def parse!(attrs) do
    Schema.parse!(@schema, attrs, :invalid_selection)
    |> then(fn parsed ->
      {known, extra} = Schema.split_extra(parsed, @known_fields)

      %__MODULE__{
        provider: Map.get(known, :provider),
        requested_model: blank_to_nil(Map.get(known, :requested_model)),
        resolved_model: blank_to_nil(Map.get(known, :resolved_model)),
        resolution_source: Map.get(known, :resolution_source),
        reasoning: blank_to_nil(Map.get(known, :reasoning)),
        reasoning_effort: Map.get(known, :reasoning_effort),
        normalized_reasoning_effort: Map.get(known, :normalized_reasoning_effort),
        model_family: blank_to_nil(Map.get(known, :model_family)),
        catalog_version: blank_to_nil(Map.get(known, :catalog_version)),
        visibility: Map.get(known, :visibility, :public),
        provider_backend: Map.get(known, :provider_backend),
        model_source: Map.get(known, :model_source, :catalog),
        env_overrides: Map.get(known, :env_overrides, %{}),
        settings_patch: Map.get(known, :settings_patch, %{}),
        backend_metadata: Map.get(known, :backend_metadata, %{}),
        errors: Map.get(known, :errors, []),
        extra: extra
      }
    end)
  end

  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs), do: parse!(attrs)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = selection) do
    Schema.to_map(selection, @known_fields)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
