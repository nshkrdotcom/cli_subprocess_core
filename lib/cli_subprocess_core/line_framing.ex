defmodule CliSubprocessCore.LineFraming do
  @moduledoc """
  Incremental newline framing for stdout and stderr stream handling.
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc """
  Creates a new framing state.
  """
  @spec new(binary()) :: t()
  def new(buffer \\ "") when is_binary(buffer) do
    %__MODULE__{buffer: buffer}
  end

  @doc """
  Pushes a binary chunk into the framer and returns complete lines.
  """
  @spec push(t(), iodata()) :: {[binary()], t()}
  def push(%__MODULE__{} = state, chunk) do
    data = state.buffer <> IO.iodata_to_binary(chunk)
    {lines, rest} = split_complete_lines(data)
    {lines, %__MODULE__{buffer: rest}}
  end

  @doc """
  Flushes a trailing partial fragment as a final line.
  """
  @spec flush(t()) :: {[binary()], t()}
  def flush(%__MODULE__{buffer: ""} = state), do: {[], state}

  def flush(%__MODULE__{buffer: buffer}) do
    final_line = strip_trailing_cr(buffer)
    {[final_line], %__MODULE__{buffer: ""}}
  end

  @doc """
  Returns `true` when there is no buffered partial line.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{buffer: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  defp split_complete_lines(data) when is_binary(data) do
    do_split_complete_lines(data, 0, 0, [])
  end

  defp do_split_complete_lines(data, start_index, cursor, acc) when cursor >= byte_size(data) do
    rest = binary_part(data, start_index, byte_size(data) - start_index)
    {Enum.reverse(acc), rest}
  end

  defp do_split_complete_lines(data, start_index, cursor, acc) do
    case :binary.at(data, cursor) do
      ?\n ->
        line_end = trim_line_end(data, start_index, cursor)
        line = binary_part(data, start_index, line_end - start_index)
        do_split_complete_lines(data, cursor + 1, cursor + 1, [line | acc])

      ?\r ->
        cond do
          cursor == byte_size(data) - 1 ->
            rest = binary_part(data, start_index, byte_size(data) - start_index)
            {Enum.reverse(acc), rest}

          :binary.at(data, cursor + 1) == ?\n ->
            line = binary_part(data, start_index, cursor - start_index)
            do_split_complete_lines(data, cursor + 2, cursor + 2, [line | acc])

          true ->
            line = binary_part(data, start_index, cursor - start_index)
            do_split_complete_lines(data, cursor + 1, cursor + 1, [line | acc])
        end

      _other ->
        do_split_complete_lines(data, start_index, cursor + 1, acc)
    end
  end

  defp trim_line_end(data, start_index, cursor) do
    if cursor > start_index and :binary.at(data, cursor - 1) == ?\r do
      cursor - 1
    else
      cursor
    end
  end

  defp strip_trailing_cr(buffer) do
    size = byte_size(buffer)

    if size > 0 and :binary.at(buffer, size - 1) == ?\r do
      binary_part(buffer, 0, size - 1)
    else
      buffer
    end
  end
end
