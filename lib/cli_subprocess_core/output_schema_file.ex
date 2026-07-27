defmodule CliSubprocessCore.OutputSchemaFile do
  @moduledoc """
  Materializes a structured-output JSON Schema onto disk for provider CLIs that
  take the schema as a **file path**.

  `codex exec` types `--output-schema` as a path and exits non-zero when it
  cannot read the file, so passing the schema inline is not a degraded mode —
  it is a hard failure. This module owns the file's whole life: creation,
  the path handed to argv, and removal.

  Removal is guaranteed by `CliSubprocessCore.EphemeralFiles`, which monitors
  the process that asked for the file. The returned cleanup function is the
  ordinary path; the monitor covers the case where the owner never gets to run
  it.
  """

  alias CliSubprocessCore.EphemeralFile

  @prefix "cli_subprocess_core_output_schema"

  @type cleanup :: (-> :ok)

  @doc """
  Writes `schema` to a temporary JSON file owned by `owner`.

  Returns `{:ok, nil, cleanup}` for a `nil` schema so callers can use one
  shape unconditionally. Fails closed: if the file cannot be written, or if no
  owner can guarantee its removal, no file is left behind and no path is
  returned.
  """
  @spec create(term(), pid()) :: {:ok, String.t() | nil, cleanup()} | {:error, term()}
  def create(schema, owner \\ self())

  def create(nil, _owner), do: {:ok, nil, fn -> :ok end}

  def create(schema, owner) when is_pid(owner) do
    with {:ok, encoded} <- encode(schema) do
      case EphemeralFile.create(encoded,
             owner: owner,
             prefix: @prefix,
             suffix: ".json"
           ) do
        {:ok, path, teardown} ->
          {:ok, path, teardown}

        {:error, {:ephemeral_file_write_failed, reason}} ->
          {:error, {:output_schema_write_failed, reason}}

        {:error, {:ephemeral_file_untrackable, reason}} ->
          {:error, {:output_schema_untrackable, reason}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp encode(schema) do
    Jason.encode(schema)
  rescue
    error -> {:error, {:invalid_output_schema, error}}
  end
end
