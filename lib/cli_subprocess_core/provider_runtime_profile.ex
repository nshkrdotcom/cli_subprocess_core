defmodule CliSubprocessCore.ProviderRuntimeProfile do
  @moduledoc """
  Application-configured provider runtime profile selection.

  Runtime profiles are an internal operator/configuration seam. They do not add
  public request options; instead they rewrite provider startup onto a configured
  Execution Plane transport surface before provider invocation and parser
  callbacks run.
  """

  alias CliSubprocessCore.ExecutionSurface

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

    with {:ok, required?} <- required?(config, provider),
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

  defp apply_profile(provider, provider_options, execution_surface, profile) do
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
