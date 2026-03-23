defmodule CliSubprocessCore.Transport.RunOptions do
  @moduledoc """
  Validated options for synchronous non-PTY command execution.
  """

  alias CliSubprocessCore.Command

  @default_timeout_ms 30_000

  @enforce_keys [:command]
  defstruct command: nil,
            stdin: nil,
            timeout: @default_timeout_ms,
            stderr: :separate,
            close_stdin: true

  @type stderr_mode :: :separate | :stdout

  @type t :: %__MODULE__{
          command: Command.t(),
          stdin: term(),
          timeout: timeout(),
          stderr: stderr_mode(),
          close_stdin: boolean()
        }

  @type validation_error ::
          {:invalid_command, term()}
          | {:invalid_args, term()}
          | {:invalid_cwd, term()}
          | {:invalid_env, term()}
          | {:invalid_clear_env, term()}
          | {:invalid_timeout, term()}
          | {:invalid_stderr, term()}
          | {:invalid_close_stdin, term()}

  @doc """
  Builds validated run options for the raw transport command lane.
  """
  @spec new(Command.t(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_run_options, validation_error()}}
  def new(%Command{} = command, opts \\ []) when is_list(opts) do
    normalized = %{
      command: command,
      stdin: Keyword.get(opts, :stdin),
      timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
      stderr: Keyword.get(opts, :stderr, :separate),
      close_stdin: Keyword.get(opts, :close_stdin, true)
    }

    with :ok <- Command.validate(command),
         :ok <- validate_timeout(normalized.timeout),
         :ok <- validate_stderr(normalized.stderr),
         :ok <- validate_close_stdin(normalized.close_stdin) do
      {:ok, struct!(__MODULE__, normalized)}
    else
      {:error, reason} -> {:error, {:invalid_run_options, reason}}
    end
  end

  @doc """
  Returns the default synchronous command timeout in milliseconds.
  """
  @spec default_timeout_ms() :: 30_000
  def default_timeout_ms, do: @default_timeout_ms

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  defp validate_stderr(mode) when mode in [:separate, :stdout], do: :ok
  defp validate_stderr(mode), do: {:error, {:invalid_stderr, mode}}

  defp validate_close_stdin(value) when is_boolean(value), do: :ok
  defp validate_close_stdin(value), do: {:error, {:invalid_close_stdin, value}}
end
