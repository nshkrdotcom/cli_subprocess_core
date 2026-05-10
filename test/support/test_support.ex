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
    previous_provider_env = Application.fetch_env(:cli_subprocess_core, :provider_cli_env)
    previous_live_ssh_env = Application.fetch_env(:cli_subprocess_core, :live_ssh_env)
    materialized_env = materialized_env(env)

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    Application.put_env(:cli_subprocess_core, :provider_cli_env, materialized_env)
    Application.put_env(:cli_subprocess_core, :live_ssh_env, materialized_env)

    try do
      fun.()
    after
      restore_app_env(:provider_cli_env, previous_provider_env)
      restore_app_env(:live_ssh_env, previous_live_ssh_env)

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp materialized_env(env) do
    env
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp restore_app_env(key, {:ok, value}),
    do: Application.put_env(:cli_subprocess_core, key, value)

  defp restore_app_env(key, :error), do: Application.delete_env(:cli_subprocess_core, key)

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
