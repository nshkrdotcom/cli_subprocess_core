defmodule CliSubprocessCore.Schema.Error do
  @moduledoc false

  defexception [:tag, :details, :message]

  @impl true
  def exception(opts) do
    tag = Keyword.fetch!(opts, :tag)
    details = Keyword.fetch!(opts, :details)
    message = "#{format_tag(tag)}: #{details.message}"

    %__MODULE__{tag: tag, details: details, message: message}
  end

  defp format_tag({left, right}), do: "#{format_tag(left)} #{format_tag(right)}"

  defp format_tag(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp format_tag(value), do: inspect(value)
end
