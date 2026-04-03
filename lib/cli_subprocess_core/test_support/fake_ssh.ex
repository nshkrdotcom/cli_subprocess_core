defmodule CliSubprocessCore.TestSupport.FakeSSH do
  @moduledoc """
  Canonical fake-SSH parity harness for exercising the real execution-surface
  path without injecting fake transport implementations.

  The harness materializes an executable `ssh` shim, records the translated SSH
  invocation into a manifest file, and then runs the translated remote command
  locally through `/bin/sh -lc`.
  """

  defstruct root_dir: nil,
            ssh_path: nil,
            manifest_path: nil

  @type t :: %__MODULE__{
          root_dir: String.t(),
          ssh_path: String.t(),
          manifest_path: String.t()
        }

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) when is_list(opts) do
    root_dir = Keyword.get(opts, :root_dir, temp_dir!("cli_subprocess_core_fake_ssh"))
    manifest_path = Keyword.get(opts, :manifest_path, Path.join(root_dir, "manifest.txt"))
    ssh_path = Path.join(root_dir, "ssh")

    File.mkdir_p!(root_dir)
    File.write!(ssh_path, script_contents(manifest_path))
    File.chmod!(ssh_path, 0o755)

    %__MODULE__{
      root_dir: root_dir,
      ssh_path: ssh_path,
      manifest_path: manifest_path
    }
  end

  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{root_dir: root_dir}) when is_binary(root_dir) do
    File.rm_rf!(root_dir)
    :ok
  end

  @spec wait_until_written(t(), non_neg_integer()) :: :ok | :timeout
  def wait_until_written(%__MODULE__{manifest_path: manifest_path}, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fn -> manifest_written?(manifest_path) end, deadline_ms)
  end

  @spec read_manifest!(t()) :: binary()
  def read_manifest!(%__MODULE__{manifest_path: manifest_path}) do
    File.read!(manifest_path)
  end

  @spec transport_options(t(), keyword()) :: keyword()
  def transport_options(%__MODULE__{ssh_path: ssh_path}, opts \\ []) when is_list(opts) do
    Keyword.put(opts, :ssh_path, ssh_path)
  end

  defp script_contents(manifest_path) do
    """
    #!/usr/bin/env bash
    set -euo pipefail

    destination=""
    port=""
    user=""
    ssh_opts=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          port="$2"
          shift 2
          ;;
        -l)
          user="$2"
          shift 2
          ;;
        -o)
          ssh_opts+=("$2")
          shift 2
          ;;
        --)
          shift
          break
          ;;
        -*)
          ssh_opts+=("$1")
          shift
          ;;
        *)
          destination="$1"
          shift
          break
          ;;
      esac
    done

    remote_command="${1:-}"

    cat > "#{manifest_path}" <<EOF
    destination=${destination}
    port=${port}
    user=${user}
    options=${ssh_opts[*]:-}
    remote_command=${remote_command}
    EOF

    exec /bin/sh -lc "$remote_command"
    """
  end

  defp temp_dir!(prefix) when is_binary(prefix) do
    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{suffix}")
    File.mkdir_p!(dir)
    dir
  end

  defp manifest_written?(manifest_path) when is_binary(manifest_path) do
    case File.stat(manifest_path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> true
      _other -> false
    end
  end

  defp wait_until(fun, deadline_ms) when is_function(fun, 0) and is_integer(deadline_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        :timeout
      else
        Process.sleep(5)
        wait_until(fun, deadline_ms)
      end
    end
  end
end
