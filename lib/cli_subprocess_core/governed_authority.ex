defmodule CliSubprocessCore.GovernedAuthority do
  @moduledoc """
  Normalized materialized authority for governed CLI launch.

  Standalone callers keep using provider CLI env, local PATH discovery, local
  config, and native provider defaults. Governed callers pass this bounded
  launch authority so command, cwd, env, and target metadata come from the
  materializer for one effect.
  """

  alias CliSubprocessCore.{Command, CommandSpec}

  @enforce_keys [
    :authority_ref,
    :credential_lease_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :provider_account_ref,
    :native_auth_assertion_ref,
    :target_ref,
    :operation_policy_ref,
    :command,
    :clear_env?
  ]
  defstruct authority_ref: nil,
            credential_lease_ref: nil,
            connector_instance_ref: nil,
            connector_binding_ref: nil,
            provider_account_ref: nil,
            native_auth_assertion_ref: nil,
            target_ref: nil,
            operation_policy_ref: nil,
            command: nil,
            cwd: nil,
            env: %{},
            clear_env?: true,
            config_root: nil,
            auth_root: nil,
            base_url: nil,
            command_ref: nil,
            redaction_ref: nil

  @type t :: %__MODULE__{
          authority_ref: String.t(),
          credential_lease_ref: String.t(),
          connector_instance_ref: String.t(),
          connector_binding_ref: String.t(),
          provider_account_ref: String.t(),
          native_auth_assertion_ref: String.t(),
          target_ref: String.t(),
          operation_policy_ref: String.t(),
          command: String.t(),
          cwd: String.t() | nil,
          env: %{optional(String.t()) => String.t()},
          clear_env?: true,
          config_root: String.t() | nil,
          auth_root: String.t() | nil,
          base_url: String.t() | nil,
          command_ref: String.t() | nil,
          redaction_ref: String.t() | nil
        }

  @type validation_error ::
          :missing_governed_authority
          | {:invalid_governed_authority, term()}
          | {:missing_governed_authority_field, atom()}
          | {:invalid_governed_authority_field, atom(), term()}
          | {:governed_launch_mismatch, atom(), term()}

  @spec new(nil | t() | keyword() | map()) :: {:ok, t() | nil} | {:error, validation_error()}
  def new(nil), do: {:ok, nil}
  def new(%__MODULE__{} = authority), do: validate(authority)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs
      |> Map.new()
      |> new()
    else
      {:error, {:invalid_governed_authority, attrs}}
    end
  end

  def new(attrs) when is_map(attrs) do
    authority = %__MODULE__{
      authority_ref: string_field(attrs, :authority_ref),
      credential_lease_ref: string_field(attrs, :credential_lease_ref),
      connector_instance_ref: string_field(attrs, :connector_instance_ref),
      connector_binding_ref: string_field(attrs, :connector_binding_ref),
      provider_account_ref: string_field(attrs, :provider_account_ref),
      native_auth_assertion_ref: string_field(attrs, :native_auth_assertion_ref),
      target_ref: string_field(attrs, :target_ref),
      operation_policy_ref: string_field(attrs, :operation_policy_ref),
      command: string_field(attrs, :materialized_command) || string_field(attrs, :command),
      cwd: string_field(attrs, :materialized_cwd) || string_field(attrs, :cwd),
      env: env_field(attrs),
      clear_env?: field(attrs, :clear_env?, field(attrs, :clear_env, true)),
      config_root: string_field(attrs, :config_root),
      auth_root: string_field(attrs, :auth_root),
      base_url: string_field(attrs, :base_url),
      command_ref: string_field(attrs, :command_ref),
      redaction_ref: string_field(attrs, :redaction_ref)
    }

    validate(authority)
  end

  def new(other), do: {:error, {:invalid_governed_authority, other}}

  @spec fetch!(nil | t() | keyword() | map()) :: t()
  def fetch!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = authority} ->
        authority

      {:ok, nil} ->
        raise ArgumentError, "missing governed authority"

      {:error, reason} ->
        raise ArgumentError, "invalid governed authority: #{inspect(reason)}"
    end
  end

  @spec command_spec(t()) :: CommandSpec.t()
  def command_spec(%__MODULE__{command: command}), do: CommandSpec.new(command)

  @spec launch_options(t()) :: keyword()
  def launch_options(%__MODULE__{} = authority) do
    [
      cwd: authority.cwd,
      env: authority.env,
      clear_env?: true
    ]
  end

  @spec enforce_invocation(Command.t(), t() | nil) :: :ok | {:error, validation_error()}
  def enforce_invocation(%Command{} = _invocation, nil), do: :ok

  def enforce_invocation(%Command{} = invocation, %__MODULE__{} = authority) do
    cond do
      invocation.command != authority.command ->
        {:error, {:governed_launch_mismatch, :command, redacted_value(invocation.command)}}

      invocation.cwd != authority.cwd ->
        {:error, {:governed_launch_mismatch, :cwd, redacted_value(invocation.cwd)}}

      invocation.env != authority.env ->
        {:error, {:governed_launch_mismatch, :env, redacted_env_keys(invocation.env)}}

      invocation.clear_env? != true ->
        {:error, {:governed_launch_mismatch, :clear_env?, invocation.clear_env?}}

      true ->
        :ok
    end
  end

  @spec redacted(t() | nil) :: map() | nil
  def redacted(nil), do: nil

  def redacted(%__MODULE__{} = authority) do
    %{
      authority_ref: authority.authority_ref,
      credential_lease_ref: authority.credential_lease_ref,
      connector_instance_ref: authority.connector_instance_ref,
      connector_binding_ref: authority.connector_binding_ref,
      provider_account_ref: authority.provider_account_ref,
      native_auth_assertion_ref: authority.native_auth_assertion_ref,
      target_ref: authority.target_ref,
      operation_policy_ref: authority.operation_policy_ref,
      command_ref: authority.command_ref,
      redaction_ref: authority.redaction_ref,
      command: redacted_value(authority.command),
      cwd: redacted_value(authority.cwd),
      env_keys: Map.keys(authority.env) |> Enum.sort(),
      clear_env?: true,
      config_root: redacted_value(authority.config_root),
      auth_root: redacted_value(authority.auth_root),
      base_url: redacted_value(authority.base_url)
    }
  end

  defp validate(%__MODULE__{} = authority) do
    with :ok <- require_binary(authority.authority_ref, :authority_ref),
         :ok <- require_binary(authority.credential_lease_ref, :credential_lease_ref),
         :ok <- require_binary(authority.connector_instance_ref, :connector_instance_ref),
         :ok <- require_binary(authority.connector_binding_ref, :connector_binding_ref),
         :ok <- require_binary(authority.provider_account_ref, :provider_account_ref),
         :ok <- require_binary(authority.native_auth_assertion_ref, :native_auth_assertion_ref),
         :ok <- require_binary(authority.target_ref, :target_ref),
         :ok <- require_binary(authority.operation_policy_ref, :operation_policy_ref),
         :ok <- require_binary(authority.command, :command),
         :ok <- optional_binary(authority.cwd, :cwd),
         :ok <- validate_env(authority.env),
         :ok <- validate_clear_env(authority.clear_env?),
         :ok <- optional_binary(authority.config_root, :config_root),
         :ok <- optional_binary(authority.auth_root, :auth_root),
         :ok <- optional_binary(authority.base_url, :base_url),
         :ok <- optional_binary(authority.command_ref, :command_ref),
         :ok <- optional_binary(authority.redaction_ref, :redaction_ref) do
      {:ok, authority}
    end
  end

  defp require_binary(value, _key) when is_binary(value) and value != "", do: :ok
  defp require_binary(nil, key), do: {:error, {:missing_governed_authority_field, key}}
  defp require_binary(value, key), do: {:error, {:invalid_governed_authority_field, key, value}}

  defp optional_binary(nil, _key), do: :ok
  defp optional_binary(value, _key) when is_binary(value), do: :ok
  defp optional_binary(value, key), do: {:error, {:invalid_governed_authority_field, key, value}}

  defp validate_clear_env(true), do: :ok

  defp validate_clear_env(value),
    do: {:error, {:invalid_governed_authority_field, :clear_env?, value}}

  defp validate_env(env) when is_map(env) do
    if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      :ok
    else
      {:error, {:invalid_governed_authority_field, :env, redacted_env_keys(env)}}
    end
  end

  defp validate_env(env), do: {:error, {:invalid_governed_authority_field, :env, env}}

  defp env_field(attrs) do
    attrs
    |> field(:materialized_env, field(attrs, :env, %{}))
    |> normalize_env()
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {normalize_env_part(key), normalize_env_part(value)} end)
  end

  defp normalize_env(other), do: other

  defp normalize_env_part(value) when is_binary(value), do: value
  defp normalize_env_part(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_env_part(value) when is_boolean(value), do: to_string(value)
  defp normalize_env_part(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_env_part(value) when is_float(value), do: Float.to_string(value)
  defp normalize_env_part(value), do: value

  defp string_field(attrs, key) do
    case field(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp field(attrs, key, default \\ nil) when is_map(attrs) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> default
    end
  end

  defp redacted_env_keys(env) when is_map(env),
    do: Map.keys(env) |> Enum.map(&redacted_env_key/1) |> Enum.sort()

  defp redacted_env_keys(_env), do: []

  defp redacted_env_key(value) when is_binary(value), do: value
  defp redacted_env_key(value) when is_atom(value), do: Atom.to_string(value)
  defp redacted_env_key(value) when is_integer(value), do: Integer.to_string(value)
  defp redacted_env_key(value), do: inspect(value)

  defp redacted_value(nil), do: nil
  defp redacted_value(value) when is_binary(value), do: "[redacted:#{byte_size(value)}]"
  defp redacted_value(value), do: inspect(value)
end
