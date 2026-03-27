defmodule CliSubprocessCore.Schema do
  @moduledoc false

  alias CliSubprocessCore.Schema.Error

  @type error_detail :: %{
          message: String.t(),
          errors: map(),
          issues: [issue_detail()]
        }

  @type issue_detail :: %{
          code: atom(),
          message: String.t(),
          path: [term()]
        }

  @type parse_error(tag) :: {tag, error_detail()}

  @spec parse(Zoi.schema(), term(), term()) :: {:ok, term()} | {:error, parse_error(term())}
  def parse(schema, value, tag) do
    case Zoi.parse(schema, value) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, errors} ->
        {:error, {tag, error_details(errors)}}
    end
  end

  @spec parse!(Zoi.schema(), term(), term()) :: term()
  def parse!(schema, value, tag) do
    case parse(schema, value, tag) do
      {:ok, parsed} ->
        parsed

      {:error, {^tag, details}} ->
        raise Error, tag: tag, details: details
    end
  end

  @spec split_extra(map(), [atom()]) :: {map(), map()}
  def split_extra(map, keys) when is_map(map) and is_list(keys) do
    known = Map.take(map, keys)
    extra = Map.drop(map, keys)
    {known, extra}
  end

  @spec merge_extra(map(), map()) :: map()
  def merge_extra(projected, extra) when is_map(projected) and is_map(extra) do
    Map.merge(projected, extra)
  end

  def merge_extra(projected, _extra) when is_map(projected), do: projected

  @spec to_map(struct(), [atom()]) :: map()
  def to_map(struct, keys) when is_struct(struct) and is_list(keys) do
    struct
    |> Map.from_struct()
    |> Map.take(keys)
    |> merge_extra(Map.get(struct, :extra, %{}))
  end

  @spec error_details([Zoi.Error.t()]) :: error_detail()
  def error_details(errors) when is_list(errors) do
    %{
      message: errors |> List.first() |> Exception.message(),
      errors: Zoi.treefy_errors(errors),
      issues: Enum.map(errors, &issue_detail/1)
    }
  end

  defp issue_detail(%Zoi.Error{} = error) do
    %{
      code: error.code,
      message: Exception.message(error),
      path: error.path
    }
  end
end
