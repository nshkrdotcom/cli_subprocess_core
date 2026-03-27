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
end
