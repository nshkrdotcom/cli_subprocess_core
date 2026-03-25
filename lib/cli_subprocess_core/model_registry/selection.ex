defmodule CliSubprocessCore.ModelRegistry.Selection do
  @moduledoc false

  @type resolution_source :: :explicit | :env | :default | :remote

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
            errors: []

  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Enum.into(attrs, %{})

    %__MODULE__{
      provider: Map.get(attrs, :provider),
      requested_model: Map.get(attrs, :requested_model),
      resolved_model: Map.get(attrs, :resolved_model),
      resolution_source: Map.get(attrs, :resolution_source),
      reasoning: Map.get(attrs, :reasoning),
      reasoning_effort: Map.get(attrs, :reasoning_effort),
      normalized_reasoning_effort: Map.get(attrs, :normalized_reasoning_effort),
      model_family: Map.get(attrs, :model_family),
      catalog_version: Map.get(attrs, :catalog_version),
      visibility: Map.get(attrs, :visibility, :public),
      errors: Map.get(attrs, :errors, [])
    }
  end
end
