defmodule CliSubprocessCore.GovernedSecurity do
  @moduledoc false

  alias CliSubprocessCore.{Command, Event, GovernedAuthority}
  alias CliSubprocessCore.Command.RunResult
  alias CliSubprocessCore.Payload.RunStarted

  @redacted "[REDACTED]"

  @supplementation_keys MapSet.new(~w(
    access_token api_key auth auth_root auth_token authorization base_url bearer_token
    client_secret command command_spec config config_root config_values credential
    credential_material credential_materialization cwd endpoint env environment executable
    headers home http_headers material ollama_base_url openai_base_url password private_key
    proxy query query_params raw_credential refresh_token route routing secret token url
    workdir working_directory
  ))

  @sensitive_suffixes ~w(
    _access_token _api_key _auth_token _authorization _bearer_token _client_secret
    _credential _password _private_key _refresh_token _secret _token
  )

  @path_env_keys MapSet.new(~w(
    CODEX_HOME CLAUDE_CONFIG_DIR HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
  ))

  @spec find_supplementation(term()) :: nil | [String.t() | non_neg_integer()]
  def find_supplementation(value), do: do_find_supplementation(value, [])

  @spec find_argv_supplementation(term()) :: nil | String.t()
  def find_argv_supplementation(args) when is_list(args) do
    Enum.find_value(args, fn
      "-" <> _rest = argument ->
        flag = argument |> String.split("=", parts: 2) |> hd() |> String.trim_leading("-")
        normalized = normalize_key(flag)
        if supplementation_key?(normalized), do: normalized

      _argument ->
        nil
    end)
  end

  def find_argv_supplementation(_args), do: nil

  @spec redact(term(), GovernedAuthority.t() | nil) :: term()
  def redact(value, nil), do: value

  def redact(value, %GovernedAuthority{} = authority) do
    do_redact(value, redaction_values(authority))
  end

  @spec sanitize_event(Event.t(), GovernedAuthority.t() | nil) :: Event.t()
  def sanitize_event(%Event{} = event, nil), do: event

  def sanitize_event(%Event{} = event, %GovernedAuthority{} = authority) do
    payload =
      case event.payload do
        %RunStarted{} = payload ->
          %RunStarted{
            payload
            | command: redact_present(payload.command),
              cwd: redact_present(payload.cwd),
              args: redact_argv(payload.args, authority),
              metadata: redact(payload.metadata, authority),
              extra: redact(payload.extra, authority)
          }

        payload ->
          redact(payload, authority)
      end

    %Event{
      event
      | payload: payload,
        raw: nil,
        provider_session_id: redact(event.provider_session_id, authority),
        metadata: redact(event.metadata, authority),
        extra: redact(event.extra, authority)
    }
  end

  @spec sanitize_run_result(RunResult.t(), GovernedAuthority.t() | nil) :: RunResult.t()
  def sanitize_run_result(%RunResult{} = result, nil), do: result

  def sanitize_run_result(%RunResult{} = result, %GovernedAuthority{} = authority) do
    %RunResult{
      result
      | output: redact(result.output, authority),
        stdout: redact(result.stdout, authority),
        stderr: redact(result.stderr, authority),
        exit: redact(result.exit, authority),
        invocation: sanitize_result_invocation(result.invocation, authority),
        execution_provenance: redact(result.execution_provenance, authority)
    }
  end

  @spec sanitize_invocation(Command.t()) :: Command.t()
  def sanitize_invocation(%Command{} = invocation) do
    %Command{
      invocation
      | command: @redacted,
        args: Enum.map(invocation.args, fn _arg -> @redacted end),
        cwd: redact_present(invocation.cwd),
        env: Map.new(invocation.env, fn {key, _value} -> {key, @redacted} end),
        user: redact_present(invocation.user)
    }
  end

  defp sanitize_result_invocation(%Command{} = invocation, authority) do
    %Command{
      invocation
      | command: @redacted,
        args: redact_argv(invocation.args, authority),
        cwd: redact_present(invocation.cwd),
        env:
          Map.new(invocation.env, fn {key, value} ->
            if secret_env_key?(key), do: {key, @redacted}, else: {key, redact(value, authority)}
          end),
        user: redact_present(invocation.user)
    }
  end

  defp do_find_supplementation(%DateTime{}, _path), do: nil

  defp do_find_supplementation(%_{} = value, path) do
    value
    |> Map.from_struct()
    |> do_find_supplementation(path)
  end

  defp do_find_supplementation(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      normalized = normalize_key(key)

      cond do
        supplementation_key?(normalized) ->
          Enum.reverse([normalized | path])

        true ->
          do_find_supplementation(nested, [normalized | path])
      end
    end)
  end

  defp do_find_supplementation(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{key, nested}, _index} when is_atom(key) or is_binary(key) ->
        normalized = normalize_key(key)

        if supplementation_key?(normalized) do
          Enum.reverse([normalized | path])
        else
          do_find_supplementation(nested, [normalized | path])
        end

      {nested, index} ->
        do_find_supplementation(nested, [index | path])
    end)
  end

  defp do_find_supplementation(_value, _path), do: nil

  defp do_redact(%DateTime{} = value, _redactions), do: value

  defp do_redact(%module{} = value, redactions) do
    attrs = value |> Map.from_struct() |> do_redact(redactions)

    if function_exported?(module, :__struct__, 0) do
      struct(module, attrs)
    else
      attrs
    end
  rescue
    _error -> @redacted
  end

  defp do_redact(value, redactions) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(normalize_key(key)) do
        {key, @redacted}
      else
        {key, do_redact(nested, redactions)}
      end
    end)
  end

  defp do_redact(value, redactions) when is_list(value) do
    Enum.map(value, &do_redact(&1, redactions))
  end

  defp do_redact(value, redactions) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&do_redact(&1, redactions))
    |> List.to_tuple()
  end

  defp do_redact(value, redactions) when is_binary(value) do
    Enum.reduce(redactions, value, fn secret, sanitized ->
      :binary.replace(sanitized, secret, @redacted, [:global])
    end)
  end

  defp do_redact(value, _redactions), do: value

  defp redaction_values(%GovernedAuthority{} = authority) do
    authority.env
    |> Enum.filter(fn {key, _value} -> secret_env_key?(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> Kernel.++([
      authority.command,
      authority.cwd,
      authority.config_root,
      authority.auth_root,
      authority.base_url
    ])
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp redact_argv(args, authority) when is_list(args) do
    args
    |> redact(authority)
    |> redact_flag_values()
  end

  defp redact_argv(_args, _authority), do: []

  defp redact_flag_values(args), do: do_redact_flag_values(args, []) |> Enum.reverse()

  defp do_redact_flag_values([], acc), do: acc

  defp do_redact_flag_values([flag, value | rest], acc) when is_binary(flag) do
    normalized = flag |> String.trim_leading("-") |> String.replace("-", "_")

    if sensitive_key?(normalized) do
      do_redact_flag_values(rest, [@redacted, flag | acc])
    else
      do_redact_flag_values([value | rest], [flag | acc])
    end
  end

  defp do_redact_flag_values([value | rest], acc),
    do: do_redact_flag_values(rest, [value | acc])

  defp supplementation_key?(key) do
    MapSet.member?(@supplementation_keys, key) or
      String.starts_with?(key, "raw_") or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  defp sensitive_key?(key), do: supplementation_key?(key)

  defp secret_env_key?(key) when is_binary(key) do
    normalized = String.upcase(key)
    MapSet.member?(@path_env_keys, normalized) or sensitive_key?(String.downcase(normalized))
  end

  defp secret_env_key?(_key), do: true

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_key(_key), do: "unknown"

  defp redact_present(nil), do: nil
  defp redact_present(_value), do: @redacted
end
