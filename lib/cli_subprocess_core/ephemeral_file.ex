defmodule CliSubprocessCore.EphemeralFile do
  @moduledoc """
  Secure, owner-tracked materialization of one temporary file.

  The file is created exclusively in the operating-system temporary directory,
  restricted to mode `0600`, and registered with
  `CliSubprocessCore.EphemeralFiles`. The returned teardown is idempotent; the
  tracker independently removes the file if its owning process dies.
  """

  alias CliSubprocessCore.EphemeralFiles

  @default_prefix "cli_subprocess_core"
  @max_prefix_bytes 64
  @max_suffix_bytes 24

  @type cleanup :: (-> :ok)

  @type option ::
          {:owner, pid()}
          | {:prefix, String.t()}
          | {:suffix, String.t()}

  @doc """
  Writes already-encoded `iodata` to a new owner-only temporary file.

  Prefixes and suffixes are bounded filename components. Paths and directories
  are not accepted as naming options, keeping cleanup limited to one generated
  file.
  """
  @spec create(iodata(), [option()]) ::
          {:ok, Path.t(), cleanup()} | {:error, term()}
  def create(iodata, opts \\ [])

  def create(iodata, opts) when is_list(opts) do
    owner = Keyword.get(opts, :owner, self())

    with :ok <- validate_owner(owner),
         {:ok, prefix} <-
           filename_component(Keyword.get(opts, :prefix, @default_prefix), @max_prefix_bytes),
         {:ok, suffix} <- filename_component(Keyword.get(opts, :suffix, ""), @max_suffix_bytes),
         {:ok, encoded} <- encode_iodata(iodata),
         {:ok, path} <- write_exclusive(encoded, prefix, suffix),
         :ok <- track(path, owner) do
      {:ok, path, fn -> EphemeralFiles.release(path) end}
    end
  end

  def create(_iodata, _opts), do: {:error, :invalid_ephemeral_file_options}

  defp validate_owner(owner) when is_pid(owner), do: :ok
  defp validate_owner(_owner), do: {:error, :invalid_ephemeral_file_owner}

  defp filename_component(component, max_bytes)
       when is_binary(component) and byte_size(component) <= max_bytes do
    if component == "" or Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, component) do
      {:ok, component}
    else
      {:error, :invalid_ephemeral_file_name}
    end
  end

  defp filename_component(_component, _max_bytes),
    do: {:error, :invalid_ephemeral_file_name}

  defp encode_iodata(iodata) do
    {:ok, IO.iodata_to_binary(iodata)}
  rescue
    ArgumentError -> {:error, :invalid_ephemeral_file_contents}
  end

  defp write_exclusive(encoded, prefix, suffix) do
    path = generated_path(prefix, suffix)

    case File.write(path, encoded, [:exclusive]) do
      :ok ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            _ = File.rm(path)
            {:error, {:ephemeral_file_write_failed, reason}}
        end

      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:ephemeral_file_write_failed, reason}}
    end
  end

  defp generated_path(prefix, suffix) do
    random =
      18
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    basename =
      Enum.join(
        [prefix, System.pid(), System.unique_integer([:positive, :monotonic]), random],
        "_"
      ) <> suffix

    Path.join(System.tmp_dir!(), basename)
  end

  defp track(path, owner) do
    case EphemeralFiles.track(path, owner) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:ephemeral_file_untrackable, reason}}
    end
  end
end
