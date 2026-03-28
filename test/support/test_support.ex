defmodule CliSubprocessCore.TestSupport do
  @moduledoc false

  def tmp_dir!(prefix \\ "cli_subprocess_core_test") do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{suffix}")
    File.mkdir_p!(dir)
    dir
  end

  def write_file!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  def write_executable!(dir, name, content) do
    path = write_file!(dir, name, content)
    File.chmod!(path, 0o755)
    path
  end

  def with_env(env, fun) when is_function(fun, 0) do
    saved = Enum.map(env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  def wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline_ms)
  end

  defp do_wait_until(fun, deadline_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        :timeout
      else
        Process.sleep(5)
        do_wait_until(fun, deadline_ms)
      end
    end
  end
end
