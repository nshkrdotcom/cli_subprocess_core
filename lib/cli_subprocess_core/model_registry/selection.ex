defmodule CliSubprocessCore.ModelRegistry.Selection do
  @moduledoc """
  Resolved model selection returned by `CliSubprocessCore.ModelRegistry`.
  """

  @type resolution_source :: :explicit | :env | :default | :remote
  @type model_source :: :catalog | :external

  @type t :: %__MODULE__{
          provider: atom(),
          requested_model: String.t() | nil,
          resolved_model: String.t(),
          resolution_source: resolution_source(),
          reasoning: String.t() | nil,
          reasoning_effort: number() | nil,
          normalized_reasoning_effort: number() | nil,
          model_family: String.t() | nil,
          catalog_version: String.t() | nil,
          visibility: :public | :private | :internal | :restricted,
          provider_backend: atom() | nil,
          model_source: model_source(),
          env_overrides: %{optional(String.t()) => String.t()},
          settings_patch: map(),
          backend_metadata: map(),
          errors: [term()]
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
            errors: []

  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Enum.into(attrs, %{})

    %__MODULE__{
      provider: fetch_attr(attrs, :provider),
      requested_model: fetch_attr(attrs, :requested_model),
      resolved_model: fetch_attr(attrs, :resolved_model),
      resolution_source: fetch_attr(attrs, :resolution_source),
      reasoning: fetch_attr(attrs, :reasoning),
      reasoning_effort: fetch_attr(attrs, :reasoning_effort),
      normalized_reasoning_effort: fetch_attr(attrs, :normalized_reasoning_effort),
      model_family: fetch_attr(attrs, :model_family),
      catalog_version: fetch_attr(attrs, :catalog_version),
      visibility: fetch_attr(attrs, :visibility, :public),
      provider_backend: fetch_attr(attrs, :provider_backend),
      model_source: fetch_attr(attrs, :model_source, :catalog),
      env_overrides: fetch_attr(attrs, :env_overrides, %{}),
      settings_patch: fetch_attr(attrs, :settings_patch, %{}),
      backend_metadata: fetch_attr(attrs, :backend_metadata, %{}),
      errors: fetch_attr(attrs, :errors, [])
    }
  end

  defp fetch_attr(attrs, key, default \\ nil) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
