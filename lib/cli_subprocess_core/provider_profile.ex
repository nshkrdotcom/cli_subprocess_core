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
  @callback build_invocation(keyword()) :: {:ok, invocation()} | {:error, term()}
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
  Validates a normalized invocation returned by a provider profile.
  """
  @spec validate_invocation(invocation()) ::
          :ok
          | {:error, {:invalid_command, term()}}
          | {:error, {:invalid_args, term()}}
          | {:error, {:invalid_cwd, term()}}
          | {:error, {:invalid_env, term()}}
  def validate_invocation(%Command{} = invocation) do
    Command.validate(invocation)
  end

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
