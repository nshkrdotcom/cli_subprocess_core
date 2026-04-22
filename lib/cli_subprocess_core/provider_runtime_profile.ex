defmodule CliSubprocessCore.ProviderRuntimeProfile do
  @moduledoc """
  Application-configured provider runtime profile selection.

  Runtime profiles are an internal operator/configuration seam. They do not add
  public request options; instead they rewrite provider startup onto a configured
  Execution Plane transport surface before provider invocation and parser
  callbacks run.
  """

  alias CliSubprocessCore.{AdapterSelectionPolicy, ExecutionSurface, LowerSimulationScenario}

  @app :cli_subprocess_core
  @config_key :provider_runtime_profiles
  @lower_simulation :lower_simulation
  @missing {__MODULE__, :missing}

  @type provider :: atom()
  @type config :: keyword() | map() | nil
  @type profile :: keyword() | map()
  @type resolve_error ::
          {:provider_runtime_profile_required, provider()}
          | {:invalid_provider_runtime_profile, provider(), term()}
          | {:unsupported_provider_runtime_profile_mode, provider(), term()}
          | {:public_simulation_selector_forbidden, provider()}

  @doc """
  Declares the Phase 6 adapter selection policy for CLI runtime profiles.
  """
  @spec adapter_selection_policy() :: AdapterSelectionPolicy.t()
  def adapter_selection_policy do
    AdapterSelectionPolicy.new!(%{
      selection_surface: "application_config",
      owner_repo: "cli_subprocess_core",
      config_key: "cli_subprocess_core.provider_runtime_profiles",
      default_value_when_unset: "normal_provider_cli",
      fail_closed_action_when_misconfigured: "reject_required_or_invalid_profile"
    })
  end

  @doc """
  Builds the owner-local Phase 6 lower scenario declaration for a runtime profile.
  """
  @spec lower_simulation_scenario!(provider(), String.t(), map() | keyword()) ::
          LowerSimulationScenario.t()
  def lower_simulation_scenario!(provider, scenario_ref, overrides \\ %{})
      when is_atom(provider) and is_binary(scenario_ref) do
    overrides = normalize_overrides!(overrides)
    provider_ref = Atom.to_string(provider)

    %{
      scenario_id: scenario_ref,
      version: "1.0.0",
      owner_repo: "cli_subprocess_core",
      route_kind: "provider_runtime_profile",
      protocol_surface: "process",
      matcher_class: "deterministic_over_input",
      status_or_exit_or_response_or_stream_or_chunk_or_fault_shape: %{
        "exit" => "configured",
        "stream" => "provider_native_stdout_stderr_frames"
      },
      no_egress_assertion: %{
        "external_egress" => "deny",
        "process_spawn" => "deny",
        "side_effect_result" => "not_attempted"
      },
      bounded_evidence_projection: %{
        "contract_version" => "ExecutionPlane.LowerSimulationEvidence.v1",
        "raw_payload_persistence" => "shape_only",
        "fingerprints" => ["input", "stdout_shape", "stderr_shape"]
      },
      input_fingerprint_ref:
        "fingerprint://cli-subprocess-core/#{provider_ref}/provider-runtime-profile/input",
      cleanup_behavior: %{
        "runtime_artifacts" => "delete",
        "durable_payload" => "deny_raw"
      }
    }
    |> Map.merge(overrides)
    |> LowerSimulationScenario.new!()
  end

  @doc """
  Applies an application-configured runtime profile for a provider.

  The supported PRELIM profile mode is `:lower_simulation`, which selects the
  Execution Plane simulated process transport and injects provider-native stdout
  or stderr frames below the existing provider parsers.
  """
  @spec resolve(provider(), keyword(), ExecutionSurface.t()) ::
          {:ok, {keyword(), ExecutionSurface.t()}} | {:error, resolve_error()}
  def resolve(provider, provider_options, %ExecutionSurface{} = execution_surface)
      when is_atom(provider) and is_list(provider_options) do
    config = Application.get_env(@app, @config_key)

    with :ok <- reject_public_simulation_selector(provider_options, provider),
         {:ok, required?} <- required?(config, provider),
         {:ok, profile} <- configured_profile(config, provider) do
      case profile do
        nil when required? ->
          {:error, {:provider_runtime_profile_required, provider}}

        nil ->
          {:ok, {provider_options, execution_surface}}

        profile ->
          apply_profile(provider, provider_options, execution_surface, profile)
      end
    end
  end

  def resolve(_provider, provider_options, execution_surface),
    do: {:ok, {provider_options, execution_surface}}

  defp normalize_overrides!(overrides) when is_map(overrides), do: overrides

  defp normalize_overrides!(overrides) when is_list(overrides) do
    if Keyword.keyword?(overrides) do
      Map.new(overrides)
    else
      raise ArgumentError, "expected keyword overrides, got: #{inspect(overrides)}"
    end
  end

  defp normalize_overrides!(overrides) do
    raise ArgumentError, "expected map or keyword overrides, got: #{inspect(overrides)}"
  end

  defp reject_public_simulation_selector(provider_options, provider) do
    if Enum.any?(provider_options, &public_simulation_entry?/1) do
      {:error, {:public_simulation_selector_forbidden, provider}}
    else
      :ok
    end
  end

  defp public_simulation_entry?({key, _value}), do: key in [:simulation, "simulation"]
  defp public_simulation_entry?(_entry), do: false

  defp apply_profile(provider, provider_options, %ExecutionSurface{} = execution_surface, profile) do
    with {:ok, @lower_simulation} <- mode(provider, profile),
         {:ok, command} <- command(provider, profile),
         {:ok, scenario_ref} <- required_profile_string(provider, profile, :scenario_ref),
         {:ok, stdout_frames} <- profile_frames(provider, profile, :stdout, :stdout_frames),
         {:ok, stderr_frames} <- profile_frames(provider, profile, :stderr, :stderr_frames),
         {:ok, exit} <- profile_exit(provider, profile),
         {:ok, observability} <- observability(provider, profile, execution_surface) do
      lower_simulation_options =
        [
          scenario_ref: scenario_ref,
          stdout_frames: stdout_frames,
          stderr_frames: stderr_frames,
          exit: exit
        ]

      rewritten_surface = %ExecutionSurface{
        execution_surface
        | surface_kind: @lower_simulation,
          transport_options: lower_simulation_options,
          target_id:
            profile_string(profile, :target_id) ||
              execution_surface.target_id ||
              "cli-runtime-profile://lower-simulation",
          lease_ref: profile_string(profile, :lease_ref) || execution_surface.lease_ref,
          surface_ref: profile_string(profile, :surface_ref) || execution_surface.surface_ref,
          boundary_class:
            profile_value(profile, :boundary_class, execution_surface.boundary_class),
          observability: observability
      }

      provider_options =
        provider_options
        |> Keyword.put(:command, command)
        |> Keyword.put(:provider_runtime_profile_ref, scenario_ref)

      {:ok, {provider_options, rewritten_surface}}
    else
      {:error, {:unsupported_mode, mode}} ->
        {:error, {:unsupported_provider_runtime_profile_mode, provider, mode}}

      {:error, reason} ->
        {:error, {:invalid_provider_runtime_profile, provider, reason}}
    end
  end

  defp required?(config, provider) do
    case config_value(config, :required?, false) do
      value when is_boolean(value) ->
        {:ok, value}

      other ->
        {:error, {:invalid_provider_runtime_profile, provider, {:invalid_required?, other}}}
    end
  end

  defp configured_profile(nil, _provider), do: {:ok, nil}

  defp configured_profile(config, provider) when is_list(config) or is_map(config) do
    profile =
      config
      |> config_value(:profiles, %{})
      |> provider_profile(provider)

    case profile do
      nil ->
        {:ok, nil}

      false ->
        {:ok, nil}

      profile when is_list(profile) or is_map(profile) ->
        if config_value(profile, :enabled?, true) == false do
          {:ok, nil}
        else
          {:ok, profile}
        end

      other ->
        {:error, {:invalid_provider_runtime_profile, provider, {:invalid_profile, other}}}
    end
  end

  defp configured_profile(config, provider),
    do: {:error, {:invalid_provider_runtime_profile, provider, {:invalid_config, config}}}

  defp mode(provider, profile) do
    profile
    |> profile_value(
      :mode,
      profile_value(profile, :adapter, profile_value(profile, :surface_kind, @lower_simulation))
    )
    |> normalize_mode(provider)
  end

  defp normalize_mode(@lower_simulation, _provider), do: {:ok, @lower_simulation}
  defp normalize_mode("lower_simulation", _provider), do: {:ok, @lower_simulation}
  defp normalize_mode(other, _provider), do: {:error, {:unsupported_mode, other}}

  defp command(provider, profile) do
    case profile_value(profile, :command, "cli-subprocess-core-lower-simulation-#{provider}") do
      command when is_binary(command) and command != "" -> {:ok, command}
      other -> {:error, {:invalid_command, other}}
    end
  end

  defp required_profile_string(provider, profile, key) do
    case profile_value(profile, key, nil) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {:missing_required_option, key, other || provider}}
    end
  end

  defp profile_string(profile, key) do
    case profile_value(profile, key, nil) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp profile_frames(provider, profile, scalar_key, list_key) do
    case {profile_value(profile, list_key, nil), profile_value(profile, scalar_key, nil)} do
      {nil, nil} ->
        {:ok, []}

      {nil, value} when is_binary(value) ->
        {:ok, [value]}

      {values, _value} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          {:ok, values}
        else
          {:error, {:invalid_frames, list_key, values}}
        end

      {values, value} ->
        {:error, {:invalid_frames, list_key, values || value || provider}}
    end
  end

  defp profile_exit(provider, profile) do
    case profile_value(profile, :exit, profile_value(profile, :exit_code, 0)) do
      :normal -> {:ok, :normal}
      "normal" -> {:ok, :normal}
      code when is_integer(code) -> {:ok, code}
      other -> {:error, {:invalid_exit, other || provider}}
    end
  end

  defp observability(_provider, profile, execution_surface) do
    profile_observability = profile_value(profile, :observability, %{})

    if is_map(profile_observability) do
      {:ok,
       execution_surface.observability
       |> Map.merge(profile_observability)
       |> Map.merge(%{
         provider_runtime_profile?: true,
         provider_runtime_adapter: @lower_simulation
       })}
    else
      {:error, {:invalid_observability, profile_observability}}
    end
  end

  defp provider_profile(profiles, provider) when is_list(profiles) or is_map(profiles) do
    config_value(profiles, provider, nil)
  end

  defp provider_profile(_profiles, _provider), do: nil

  defp profile_value(profile, key, default) do
    case config_value(profile, key, @missing) do
      @missing ->
        transport_options = config_value(profile, :transport_options, %{})

        case config_value(transport_options, key, @missing) do
          @missing -> default
          nil -> default
          value -> value
        end

      nil ->
        default

      value ->
        value
    end
  end

  defp config_value(nil, _key, default), do: default

  defp config_value(config, key, default) when is_list(config) do
    case Enum.find(config, &matching_key?(&1, key)) do
      {_key, value} -> value
      nil -> default
    end
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp matching_key?({key, _value}, key), do: true

  defp matching_key?({entry_key, _value}, key) when is_binary(entry_key) and is_atom(key) do
    entry_key == Atom.to_string(key)
  end

  defp matching_key?(_entry, _key), do: false
end
