defmodule CliSubprocessCore.LineageFact do
  @moduledoc """
  Stable raw fact shapes for provider pressure, reconnect, and subprocess lineage.
  """

  @kinds [:pressure, :reconnect, :subprocess]

  @type kind :: :pressure | :reconnect | :subprocess
  @type t :: %{
          required(:fact_id) => String.t(),
          required(:kind) => kind(),
          optional(:provider) => atom() | nil,
          optional(:provider_session_id) => String.t() | nil,
          optional(:lane_session_id) => String.t() | nil,
          optional(:subprocess_id) => String.t() | nil,
          optional(:reason) => atom() | String.t() | nil,
          optional(:observed_at) => String.t() | nil,
          optional(:metadata) => map()
        }

  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @spec fact_id(kind(), String.t(), non_neg_integer()) :: String.t()
  def fact_id(kind, provider_session_id, seq)
      when kind in @kinds and is_binary(provider_session_id) and is_integer(seq) and seq >= 0 do
    "cli_fact:#{kind}:#{provider_session_id}:#{seq}"
  end

  @spec pressure(map()) :: t()
  def pressure(attrs) when is_map(attrs), do: build(:pressure, attrs)

  @spec reconnect(map()) :: t()
  def reconnect(attrs) when is_map(attrs), do: build(:reconnect, attrs)

  @spec subprocess(map()) :: t()
  def subprocess(attrs) when is_map(attrs), do: build(:subprocess, attrs)

  defp build(kind, attrs) do
    attrs = Map.new(attrs)
    provider_session_id = fetch_required_string!(attrs, :provider_session_id)
    seq = Map.get(attrs, :seq, Map.get(attrs, "seq", 0))

    %{
      fact_id: fact_id(kind, provider_session_id, seq),
      kind: kind,
      provider: normalize_provider(Map.get(attrs, :provider, Map.get(attrs, "provider"))),
      provider_session_id: provider_session_id,
      lane_session_id: fetch_optional_string(attrs, :lane_session_id),
      subprocess_id: fetch_optional_string(attrs, :subprocess_id),
      reason: Map.get(attrs, :reason, Map.get(attrs, "reason")),
      observed_at: fetch_optional_string(attrs, :observed_at),
      metadata: normalize_map(Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{})))
    }
  end

  defp fetch_required_string!(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      other -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> nil
      value when is_binary(value) and byte_size(value) > 0 -> value
      other -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp normalize_provider(nil), do: nil
  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(provider) when is_binary(provider), do: String.to_atom(provider)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
end
