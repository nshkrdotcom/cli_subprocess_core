defmodule CliSubprocessCore.LowerSimulationScenario do
  @moduledoc """
  Phase 6 lower simulation scenario declaration for CLI subprocess profiles.

  The CLI owner surface is process-only: configured runtime profiles emit
  provider-native stdout/stderr frames below the existing parser layer without
  exposing request-time simulation selectors.
  """

  alias ExecutionPlane.Contracts

  @contract_version Contracts.contract_version!(:lower_simulation_scenario_v1)
  @evidence_contract_version Contracts.contract_version!(:lower_simulation_evidence_v1)
  @owner_repo "cli_subprocess_core"
  @protocol_surfaces ["process"]
  @matcher_classes ["deterministic_over_input", "artifact_ref", "frozen_fixture"]
  @forbidden_semantic_keys [
    :provider_refs,
    :model_refs,
    :budget_profile_ref,
    :meter_profile_ref,
    :semantic_policy,
    :cost_policy
  ]

  defstruct [
    :contract_version,
    :scenario_id,
    :version,
    :owner_repo,
    :route_kind,
    :protocol_surface,
    :matcher_class,
    :status_or_exit_or_response_or_stream_or_chunk_or_fault_shape,
    :no_egress_assertion,
    :bounded_evidence_projection,
    :input_fingerprint_ref,
    :cleanup_behavior
  ]

  @type t :: %__MODULE__{
          contract_version: String.t(),
          scenario_id: String.t(),
          version: String.t(),
          owner_repo: String.t(),
          route_kind: String.t(),
          protocol_surface: String.t(),
          matcher_class: String.t(),
          status_or_exit_or_response_or_stream_or_chunk_or_fault_shape: map(),
          no_egress_assertion: map(),
          bounded_evidence_projection: map(),
          input_fingerprint_ref: String.t(),
          cleanup_behavior: map()
        }

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec owner_repo() :: String.t()
  def owner_repo, do: @owner_repo

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = value), do: {:ok, value}

  def new(attrs) do
    {:ok, build(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(map() | keyword() | t()) :: t()
  def new!(%__MODULE__{} = value), do: value

  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = scenario) do
    scenario
    |> Map.from_struct()
    |> Map.update!(
      :status_or_exit_or_response_or_stream_or_chunk_or_fault_shape,
      &Contracts.stringify_keys/1
    )
    |> Map.update!(:no_egress_assertion, &Contracts.stringify_keys/1)
    |> Map.update!(:bounded_evidence_projection, &Contracts.stringify_keys/1)
    |> Map.update!(:cleanup_behavior, &Contracts.stringify_keys/1)
    |> stringify_contract()
  end

  defp build(attrs) do
    attrs = Contracts.normalize_attrs(attrs)
    reject_semantic_provider_policy!(attrs)

    %__MODULE__{
      contract_version: Contracts.validate_contract_version!(attrs, @contract_version),
      scenario_id:
        Contracts.validate_opaque_handle_ref!(
          Contracts.fetch_required_stringish!(attrs, :scenario_id),
          "scenario_id"
        ),
      version: validate_semver!(Contracts.fetch_required_stringish!(attrs, :version)),
      owner_repo: validate_owner_repo!(Contracts.fetch_required_stringish!(attrs, :owner_repo)),
      route_kind: Contracts.fetch_required_stringish!(attrs, :route_kind),
      protocol_surface:
        attrs
        |> Contracts.fetch_required_stringish!(:protocol_surface)
        |> validate_supported!("protocol_surface", @protocol_surfaces),
      matcher_class:
        attrs
        |> Contracts.fetch_required_stringish!(:matcher_class)
        |> validate_supported!("matcher_class", @matcher_classes),
      status_or_exit_or_response_or_stream_or_chunk_or_fault_shape: normalize_shape!(attrs),
      no_egress_assertion: validate_no_egress_assertion!(attrs),
      bounded_evidence_projection: validate_bounded_evidence_projection!(attrs),
      input_fingerprint_ref:
        Contracts.validate_opaque_handle_ref!(
          Contracts.fetch_required_stringish!(attrs, :input_fingerprint_ref),
          "input_fingerprint_ref"
        ),
      cleanup_behavior: validate_cleanup_behavior!(attrs)
    }
  end

  defp reject_semantic_provider_policy!(attrs) do
    if Enum.any?(@forbidden_semantic_keys, &has_key?(attrs, &1)) do
      raise ArgumentError, "semantic provider policy must not be owned by CLI lower scenarios"
    end
  end

  defp has_key?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp validate_supported!(value, field_name, supported) do
    if value in supported do
      value
    else
      raise ArgumentError, "#{field_name} unsupported value: #{inspect(value)}"
    end
  end

  defp validate_owner_repo!(@owner_repo), do: @owner_repo

  defp validate_owner_repo!(owner_repo) do
    raise ArgumentError, "owner_repo must be #{@owner_repo}, got: #{inspect(owner_repo)}"
  end

  defp validate_semver!(version) do
    case Version.parse(version) do
      {:ok, _version} ->
        version

      :error ->
        raise ArgumentError, "version must be semantic version, got: #{inspect(version)}"
    end
  end

  defp normalize_shape!(attrs) do
    attrs
    |> Contracts.fetch_required_map!(
      :status_or_exit_or_response_or_stream_or_chunk_or_fault_shape
    )
    |> Contracts.stringify_keys()
  end

  defp validate_no_egress_assertion!(attrs) do
    assertion =
      attrs
      |> Contracts.fetch_required_map!(:no_egress_assertion)
      |> Contracts.stringify_keys()

    unless Map.get(assertion, "external_egress") == "deny" do
      raise ArgumentError, "no_egress_assertion.external_egress must be deny"
    end

    unless Map.get(assertion, "process_spawn") == "deny" do
      raise ArgumentError, "no_egress_assertion.process_spawn must be deny"
    end

    assertion
  end

  defp validate_bounded_evidence_projection!(attrs) do
    projection =
      attrs
      |> Contracts.fetch_required_map!(:bounded_evidence_projection)
      |> Contracts.stringify_keys()

    if Map.get(projection, "target_contract") == "ExecutionOutcome.v1.raw_payload" do
      raise ArgumentError, "ExecutionOutcome.v1.raw_payload must not be narrowed in place"
    end

    unless Map.get(projection, "contract_version") == @evidence_contract_version do
      raise ArgumentError,
            "bounded_evidence_projection.contract_version must be #{@evidence_contract_version}"
    end

    unless Map.get(projection, "raw_payload_persistence") == "shape_only" do
      raise ArgumentError,
            "bounded_evidence_projection.raw_payload_persistence must be shape_only"
    end

    projection
  end

  defp validate_cleanup_behavior!(attrs) do
    attrs
    |> Contracts.fetch_required_map!(:cleanup_behavior)
    |> Contracts.stringify_keys()
  end

  defp stringify_contract(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end
end
