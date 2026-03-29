defmodule CliSubprocessCore.ExecutionSurface.Capabilities do
  @moduledoc """
  Typed transport-family and per-session execution-surface capabilities.
  """

  defstruct remote?: false,
            startup_kind: :spawn,
            path_semantics: :local,
            supports_run?: true,
            supports_streaming_stdio?: true,
            supports_pty?: true,
            supports_user?: true,
            supports_env?: true,
            supports_cwd?: true,
            interrupt_kind: :signal

  @type startup_kind :: :spawn | :attach | :bridge
  @type path_semantics :: :local | :remote | :guest
  @type interrupt_kind :: :signal | :stdin | :rpc | :none

  @type t :: %__MODULE__{
          remote?: boolean(),
          startup_kind: startup_kind(),
          path_semantics: path_semantics(),
          supports_run?: boolean(),
          supports_streaming_stdio?: boolean(),
          supports_pty?: boolean(),
          supports_user?: boolean(),
          supports_env?: boolean(),
          supports_cwd?: boolean(),
          interrupt_kind: interrupt_kind()
        }

  @type validation_error ::
          {:invalid_capabilities, term()}
          | {:invalid_remote, term()}
          | {:invalid_startup_kind, term()}
          | {:invalid_path_semantics, term()}
          | {:invalid_supports_run, term()}
          | {:invalid_supports_streaming_stdio, term()}
          | {:invalid_supports_pty, term()}
          | {:invalid_supports_user, term()}
          | {:invalid_supports_env, term()}
          | {:invalid_supports_cwd, term()}
          | {:invalid_interrupt_kind, term()}

  @capability_keys [
    :remote?,
    :startup_kind,
    :path_semantics,
    :supports_run?,
    :supports_streaming_stdio?,
    :supports_pty?,
    :supports_user?,
    :supports_env?,
    :supports_cwd?,
    :interrupt_kind
  ]

  @type key ::
          :remote?
          | :startup_kind
          | :path_semantics
          | :supports_run?
          | :supports_streaming_stdio?
          | :supports_pty?
          | :supports_user?
          | :supports_env?
          | :supports_cwd?
          | :interrupt_kind

  @spec keys() :: [key(), ...]
  def keys, do: @capability_keys

  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(%__MODULE__{} = capabilities), do: {:ok, capabilities}

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> new()
    else
      {:error, {:invalid_capabilities, attrs}}
    end
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, remote?} <- validate_boolean(fetch(attrs, :remote?), :invalid_remote),
         {:ok, startup_kind} <-
           validate_member(
             fetch(attrs, :startup_kind),
             [:spawn, :attach, :bridge],
             :invalid_startup_kind
           ),
         {:ok, path_semantics} <-
           validate_member(
             fetch(attrs, :path_semantics),
             [:local, :remote, :guest],
             :invalid_path_semantics
           ),
         {:ok, supports_run?} <-
           validate_boolean(fetch(attrs, :supports_run?), :invalid_supports_run),
         {:ok, supports_streaming_stdio?} <-
           validate_boolean(
             fetch(attrs, :supports_streaming_stdio?),
             :invalid_supports_streaming_stdio
           ),
         {:ok, supports_pty?} <-
           validate_boolean(fetch(attrs, :supports_pty?), :invalid_supports_pty),
         {:ok, supports_user?} <-
           validate_boolean(fetch(attrs, :supports_user?), :invalid_supports_user),
         {:ok, supports_env?} <-
           validate_boolean(fetch(attrs, :supports_env?), :invalid_supports_env),
         {:ok, supports_cwd?} <-
           validate_boolean(fetch(attrs, :supports_cwd?), :invalid_supports_cwd),
         {:ok, interrupt_kind} <-
           validate_member(
             fetch(attrs, :interrupt_kind),
             [:signal, :stdin, :rpc, :none],
             :invalid_interrupt_kind
           ) do
      {:ok,
       %__MODULE__{
         remote?: remote?,
         startup_kind: startup_kind,
         path_semantics: path_semantics,
         supports_run?: supports_run?,
         supports_streaming_stdio?: supports_streaming_stdio?,
         supports_pty?: supports_pty?,
         supports_user?: supports_user?,
         supports_env?: supports_env?,
         supports_cwd?: supports_cwd?,
         interrupt_kind: interrupt_kind
       }}
    end
  end

  def new(other), do: {:error, {:invalid_capabilities, other}}

  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = capabilities} ->
        capabilities

      {:error, reason} ->
        raise ArgumentError, "invalid execution-surface capabilities: #{inspect(reason)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = capabilities) do
    Map.take(capabilities, @capability_keys)
  end

  @spec subset?(t(), t()) :: boolean()
  def subset?(%__MODULE__{} = effective, %__MODULE__{} = maximum) do
    [
      effective.remote? == maximum.remote?,
      effective.startup_kind == maximum.startup_kind,
      effective.path_semantics == maximum.path_semantics,
      weaker_boolean?(effective.supports_run?, maximum.supports_run?),
      weaker_boolean?(effective.supports_streaming_stdio?, maximum.supports_streaming_stdio?),
      weaker_boolean?(effective.supports_pty?, maximum.supports_pty?),
      weaker_boolean?(effective.supports_user?, maximum.supports_user?),
      weaker_boolean?(effective.supports_env?, maximum.supports_env?),
      weaker_boolean?(effective.supports_cwd?, maximum.supports_cwd?),
      weaker_interrupt_kind?(effective.interrupt_kind, maximum.interrupt_kind)
    ]
    |> Enum.all?()
  end

  @spec satisfies_requirements?(t(), map() | keyword() | t()) :: boolean()
  def satisfies_requirements?(%__MODULE__{} = effective, %__MODULE__{} = required) do
    satisfies_requirements?(effective, to_map(required))
  end

  def satisfies_requirements?(%__MODULE__{} = effective, required) when is_list(required) do
    if Keyword.keyword?(required) do
      satisfies_requirements?(effective, Map.new(required))
    else
      false
    end
  end

  def satisfies_requirements?(%__MODULE__{} = effective, required) when is_map(required) do
    Enum.all?(required, fn
      {:remote?, value} -> effective.remote? == value
      {"remote?", value} -> effective.remote? == value
      {:startup_kind, value} -> effective.startup_kind == normalize_atomish(value)
      {"startup_kind", value} -> effective.startup_kind == normalize_atomish(value)
      {:path_semantics, value} -> effective.path_semantics == normalize_atomish(value)
      {"path_semantics", value} -> effective.path_semantics == normalize_atomish(value)
      {:supports_run?, value} -> effective.supports_run? == value
      {"supports_run?", value} -> effective.supports_run? == value
      {:supports_streaming_stdio?, value} -> effective.supports_streaming_stdio? == value
      {"supports_streaming_stdio?", value} -> effective.supports_streaming_stdio? == value
      {:supports_pty?, value} -> effective.supports_pty? == value
      {"supports_pty?", value} -> effective.supports_pty? == value
      {:supports_user?, value} -> effective.supports_user? == value
      {"supports_user?", value} -> effective.supports_user? == value
      {:supports_env?, value} -> effective.supports_env? == value
      {"supports_env?", value} -> effective.supports_env? == value
      {:supports_cwd?, value} -> effective.supports_cwd? == value
      {"supports_cwd?", value} -> effective.supports_cwd? == value
      {:interrupt_kind, value} -> effective.interrupt_kind == normalize_atomish(value)
      {"interrupt_kind", value} -> effective.interrupt_kind == normalize_atomish(value)
      _other -> false
    end)
  end

  def satisfies_requirements?(_effective, _required), do: false

  defp fetch(attrs, key) when is_map(attrs) do
    default = Map.get(%__MODULE__{}, key)
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp validate_boolean(value, _reason) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(value, reason), do: {:error, {reason, value}}

  defp validate_member(value, allowed, reason) when is_list(allowed) do
    if value in allowed do
      {:ok, value}
    else
      {:error, {reason, value}}
    end
  end

  defp weaker_boolean?(false, _maximum), do: true
  defp weaker_boolean?(true, true), do: true
  defp weaker_boolean?(_effective, _maximum), do: false

  defp weaker_interrupt_kind?(kind, kind), do: true
  defp weaker_interrupt_kind?(:none, _maximum), do: true
  defp weaker_interrupt_kind?(_effective, _maximum), do: false

  defp normalize_atomish(value) when is_atom(value), do: value

  defp normalize_atomish(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_atomish(_other), do: nil
end
