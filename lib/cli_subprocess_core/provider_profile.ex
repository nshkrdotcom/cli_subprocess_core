defmodule CliSubprocessCore.ProviderProfile do
  @moduledoc """
  Behaviour contract for built-in and external provider CLI profiles.
  """

  alias CliSubprocessCore.{Command, Event}

  @typedoc "Normalized provider identifier."
  @type id :: atom()

  @typedoc "Normalized invocation returned by a provider profile."
  @type invocation :: Command.t()

  @typedoc "Parser state owned by an individual provider profile."
  @type parser_state :: term()

  @typedoc "Event decode result returned by parser callbacks."
  @type decode_result :: {[Event.t()], parser_state()}

  @typedoc """
  Releases resources an invocation needed on disk or in memory for the lifetime
  of the run. Idempotent, bounded, and safe to call from any process.
  """
  @type teardown :: (-> :ok)

  @typedoc """
  What `build_invocation/1` returns.

  A profile that materializes a resource for the run — a Codex output-schema
  file is the shipped example — returns it with a teardown the run's owner is
  responsible for calling. Owner death is covered independently by
  `CliSubprocessCore.EphemeralFiles`.
  """
  @type build_result ::
          {:ok, invocation()} | {:ok, invocation(), teardown()} | {:error, term()}

  @type callback_spec ::
          {:id, 0}
          | {:capabilities, 0}
          | {:build_invocation, 1}
          | {:init_parser_state, 1}
          | {:decode_stdout, 2}
          | {:decode_stderr, 2}
          | {:handle_exit, 2}
          | {:transport_options, 1}

  @callback id() :: id()
  @callback capabilities() :: [atom()]
  @callback build_invocation(keyword()) :: build_result()
  @callback init_parser_state(keyword()) :: parser_state()
  @callback decode_stdout(binary(), parser_state()) :: decode_result()
  @callback decode_stderr(binary(), parser_state()) :: decode_result()
  @callback handle_exit(term(), parser_state()) :: decode_result()
  @callback transport_options(keyword()) :: keyword()

  @required_callbacks [
    id: 0,
    capabilities: 0,
    build_invocation: 1,
    init_parser_state: 1,
    decode_stdout: 2,
    decode_stderr: 2,
    handle_exit: 2,
    transport_options: 1
  ]

  @doc """
  Returns the callbacks required by the provider profile contract.
  """
  @spec required_callbacks() :: nonempty_list(callback_spec())
  def required_callbacks, do: @required_callbacks

  @doc """
  Validates that a module satisfies the provider profile contract.
  """
  @spec ensure_module(module()) ::
          :ok
          | {:error, {:module_not_loaded, module()}}
          | {:error, {:missing_callbacks, module(), [{atom(), non_neg_integer()}]}}
          | {:error, {:behaviour_not_declared, module()}}
  def ensure_module(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:module_not_loaded, module}}

      missing_callbacks(module) != [] ->
        {:error, {:missing_callbacks, module, missing_callbacks(module)}}

      not declares_behaviour?(module) ->
        {:error, {:behaviour_not_declared, module}}

      true ->
        :ok
    end
  end

  @doc """
  Whether a lane can be given more input after its run has started.

  This is the fact a caller needs to decide *how* to say something to a session
  already in flight: write to it, or interrupt the turn and resume the thread.

  Two conditions, and both are required. The transport must leave stdin open,
  and the profile must declare `:incremental_input` — that it invokes the CLI
  in a mode which keeps *reading* stdin once the turn is running.

  An open file descriptor is not the same as a reader. `claude --print` takes
  its prompt on argv, consumes stdin once while assembling that prompt, and
  never reads it again; the descriptor stays open for the life of the process
  and writing to it mid-turn reaches nobody. Deriving this from
  `close_stdin_on_start?` alone therefore reported `claude` as accepting live
  input, and a caller acting on that had its message silently swallowed while
  every layer above reported success. Verified against the shipping CLI: text
  piped before the turn changes the answer, and the same text written eight
  seconds in does not.

  No shipped profile declares `:incremental_input` today, so every lane is
  steered by interrupt and resume. A profile that switches to a streaming input
  mode declares it and changes this with it.

  It is not `:interrupt` or `:resume` from `capabilities/0` — every profile
  declares those, and they do not distinguish the two mechanisms.
  """
  @incremental_input :incremental_input

  @spec accepts_input_after_start?(module()) :: boolean()
  def accepts_input_after_start?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and stdin_stays_open?(module) and
      @incremental_input in module.capabilities()
  end

  defp stdin_stays_open?(module) do
    module.transport_options([]) |> Keyword.get(:close_stdin_on_start?, false) |> Kernel.not()
  end

  @doc """
  Validates a normalized invocation returned by a provider profile.
  """
  @spec validate_invocation(invocation()) ::
          :ok
          | {:error, {:invalid_command, term()}}
          | {:error, {:invalid_args, term()}}
          | {:error, {:invalid_cwd, term()}}
          | {:error, {:invalid_env, term()}}
          | {:error, {:invalid_clear_env, term()}}
  def validate_invocation(%Command{} = invocation) do
    Command.validate(invocation)
  end

  @doc """
  Normalizes a `build_invocation/1` return into `{invocation, teardown}`.

  A profile that materializes nothing returns the two-element form, and gets a
  no-op teardown, so every caller can use one shape.
  """
  @spec normalize_build_result(build_result()) ::
          {:ok, invocation(), teardown()} | {:error, term()}
  def normalize_build_result({:ok, %Command{} = invocation}),
    do: {:ok, invocation, fn -> :ok end}

  def normalize_build_result({:ok, %Command{} = invocation, teardown})
      when is_function(teardown, 0),
      do: {:ok, invocation, teardown}

  def normalize_build_result({:error, _reason} = error), do: error

  def normalize_build_result(other), do: {:error, {:invalid_build_invocation, other}}

  defp missing_callbacks(module) do
    Enum.reject(@required_callbacks, fn {name, arity} ->
      function_exported?(module, name, arity)
    end)
  end

  defp declares_behaviour?(module) do
    module
    |> Kernel.apply(:__info__, [:attributes])
    |> Keyword.get(:behaviour, [])
    |> Enum.member?(__MODULE__)
  end
end
