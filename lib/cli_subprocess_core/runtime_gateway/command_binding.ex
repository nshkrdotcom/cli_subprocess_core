defmodule CliSubprocessCore.RuntimeGateway.CommandBinding do
  @moduledoc false

  alias CliSubprocessCore.GovernedAuthority

  @spec digest(GovernedAuthority.t()) :: String.t()
  def digest(%GovernedAuthority{} = authority) do
    material = [
      authority.command,
      authority.cwd || "",
      authority.clear_env?,
      authority.env |> Map.keys() |> Enum.sort()
    ]

    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(material, [:deterministic]))
       |> Base.encode16(case: :lower))
  end
end
