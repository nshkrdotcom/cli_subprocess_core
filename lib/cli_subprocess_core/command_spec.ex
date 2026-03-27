defmodule CliSubprocessCore.CommandSpec do
  @moduledoc """
  Resolved subprocess program plus any argv prefix that must precede provider
  arguments.

  This lets core-owned provider resolution express launchers such as
  `npx --yes --package @google/gemini-cli gemini ...` while still projecting to
  a normal `CliSubprocessCore.Command` invocation for transport execution.
  """

  @enforce_keys [:program]
  defstruct program: nil, argv_prefix: []

  @type t :: %__MODULE__{
          program: String.t(),
          argv_prefix: [String.t()]
        }

  @spec new(String.t(), keyword()) :: t()
  def new(program, opts \\ []) when is_binary(program) and is_list(opts) do
    %__MODULE__{
      program: program,
      argv_prefix: normalize_argv_prefix(Keyword.get(opts, :argv_prefix, []))
    }
  end

  @spec command_args(t(), [String.t()]) :: [String.t()]
  def command_args(%__MODULE__{argv_prefix: argv_prefix}, args) when is_list(args) do
    argv_prefix ++ args
  end

  defp normalize_argv_prefix(argv_prefix) when is_list(argv_prefix) do
    Enum.flat_map(argv_prefix, fn
      value when is_binary(value) and value != "" -> [value]
      _other -> []
    end)
  end

  defp normalize_argv_prefix(_other), do: []
end
