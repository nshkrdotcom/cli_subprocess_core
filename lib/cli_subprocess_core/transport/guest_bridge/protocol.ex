defmodule CliSubprocessCore.Transport.GuestBridge.Protocol do
  @moduledoc false

  alias CliSubprocessCore.ExecutionSurface.Capabilities

  @version 1

  def version, do: @version

  def request(id, op, payload) when is_binary(id) and is_binary(op) and is_map(payload) do
    %{"v" => @version, "kind" => "request", "id" => id, "op" => op, "payload" => payload}
  end

  def response(id, ok, payload, error \\ nil)
      when is_binary(id) and is_boolean(ok) and is_map(payload) and
             (is_map(error) or is_nil(error)) do
    %{
      "v" => @version,
      "kind" => "response",
      "id" => id,
      "ok" => ok,
      "payload" => payload,
      "error" => error
    }
  end

  def event(event_name, payload) when is_binary(event_name) and is_map(payload) do
    %{"v" => @version, "kind" => "event", "event" => event_name, "payload" => payload}
  end

  def encode_frame(frame) when is_map(frame) do
    json = Jason.encode!(frame)
    <<byte_size(json)::unsigned-big-32, json::binary>>
  end

  @spec decode_frames(binary()) :: {:ok, [map()], binary()} | {:error, term()}
  def decode_frames(buffer) when is_binary(buffer) do
    do_decode_frames(buffer, [])
  end

  @spec encode_bytes(binary()) :: String.t()
  def encode_bytes(binary) when is_binary(binary), do: Base.encode64(binary)

  @spec decode_bytes(binary() | nil) :: :error | {:ok, binary() | nil}
  def decode_bytes(nil), do: {:ok, nil}

  def decode_bytes(encoded) when is_binary(encoded) do
    Base.decode64(encoded)
  end

  @spec capabilities_to_external(Capabilities.t() | map() | keyword()) :: map()
  def capabilities_to_external(%Capabilities{} = capabilities) do
    capabilities
    |> Capabilities.to_map()
    |> capabilities_to_external()
  end

  def capabilities_to_external(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> capabilities_to_external()
    else
      %{}
    end
  end

  def capabilities_to_external(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {:remote?, value}, acc ->
        Map.put(acc, "remote?", value)

      {:startup_kind, value}, acc ->
        Map.put(acc, "startup_kind", encode_atomish(value))

      {:path_semantics, value}, acc ->
        Map.put(acc, "path_semantics", encode_atomish(value))

      {:supports_run?, value}, acc ->
        Map.put(acc, "supports_run?", value)

      {:supports_streaming_stdio?, value}, acc ->
        Map.put(acc, "supports_streaming_stdio?", value)

      {:supports_pty?, value}, acc ->
        Map.put(acc, "supports_pty?", value)

      {:supports_user?, value}, acc ->
        Map.put(acc, "supports_user?", value)

      {:supports_env?, value}, acc ->
        Map.put(acc, "supports_env?", value)

      {:supports_cwd?, value}, acc ->
        Map.put(acc, "supports_cwd?", value)

      {:interrupt_kind, value}, acc ->
        Map.put(acc, "interrupt_kind", encode_atomish(value))

      {"remote?", value}, acc ->
        Map.put(acc, "remote?", value)

      {"startup_kind", value}, acc ->
        Map.put(acc, "startup_kind", encode_atomish(value))

      {"path_semantics", value}, acc ->
        Map.put(acc, "path_semantics", encode_atomish(value))

      {"supports_run?", value}, acc ->
        Map.put(acc, "supports_run?", value)

      {"supports_streaming_stdio?", value}, acc ->
        Map.put(acc, "supports_streaming_stdio?", value)

      {"supports_pty?", value}, acc ->
        Map.put(acc, "supports_pty?", value)

      {"supports_user?", value}, acc ->
        Map.put(acc, "supports_user?", value)

      {"supports_env?", value}, acc ->
        Map.put(acc, "supports_env?", value)

      {"supports_cwd?", value}, acc ->
        Map.put(acc, "supports_cwd?", value)

      {"interrupt_kind", value}, acc ->
        Map.put(acc, "interrupt_kind", encode_atomish(value))

      _other, acc ->
        acc
    end)
  end

  def capabilities_to_external(_other), do: %{}

  @spec capabilities_from_external(map()) :: {:ok, Capabilities.t()} | {:error, term()}
  def capabilities_from_external(attrs) when is_map(attrs) do
    Capabilities.new(%{
      remote?: Map.get(attrs, "remote?", Map.get(attrs, :remote?, false)),
      startup_kind:
        decode_atomish(Map.get(attrs, "startup_kind", Map.get(attrs, :startup_kind, :spawn))),
      path_semantics:
        decode_atomish(Map.get(attrs, "path_semantics", Map.get(attrs, :path_semantics, :local))),
      supports_run?: Map.get(attrs, "supports_run?", Map.get(attrs, :supports_run?, true)),
      supports_streaming_stdio?:
        Map.get(
          attrs,
          "supports_streaming_stdio?",
          Map.get(attrs, :supports_streaming_stdio?, true)
        ),
      supports_pty?: Map.get(attrs, "supports_pty?", Map.get(attrs, :supports_pty?, true)),
      supports_user?: Map.get(attrs, "supports_user?", Map.get(attrs, :supports_user?, true)),
      supports_env?: Map.get(attrs, "supports_env?", Map.get(attrs, :supports_env?, true)),
      supports_cwd?: Map.get(attrs, "supports_cwd?", Map.get(attrs, :supports_cwd?, true)),
      interrupt_kind:
        decode_atomish(Map.get(attrs, "interrupt_kind", Map.get(attrs, :interrupt_kind, :none)))
    })
  end

  def capabilities_from_external(other), do: {:error, {:invalid_capabilities_payload, other}}

  defp do_decode_frames(<<>>, frames), do: {:ok, Enum.reverse(frames), <<>>}

  defp do_decode_frames(buffer, frames) when byte_size(buffer) < 4 do
    {:ok, Enum.reverse(frames), buffer}
  end

  defp do_decode_frames(<<length::unsigned-big-32, rest::binary>> = buffer, frames) do
    if byte_size(rest) < length do
      {:ok, Enum.reverse(frames), buffer}
    else
      <<json::binary-size(length), tail::binary>> = rest

      case Jason.decode(json) do
        {:ok, %{} = frame} ->
          do_decode_frames(tail, [frame | frames])

        {:ok, other} ->
          {:error, {:invalid_frame_payload, other}}

        {:error, reason} ->
          {:error, {:invalid_json_frame, reason}}
      end
    end
  end

  defp encode_atomish(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atomish(value), do: value

  defp decode_atomish(value) when is_atom(value), do: value

  defp decode_atomish(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp decode_atomish(value), do: value
end
