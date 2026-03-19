defmodule CliSubprocessCore.TaskSupportTest do
  use ExUnit.Case, async: true

  alias CliSubprocessCore.TaskSupport

  setup do
    supervisor = Module.concat(__MODULE__, :"Supervisor#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: supervisor})
    %{supervisor: supervisor}
  end

  test "starts and awaits async tasks", %{supervisor: supervisor} do
    assert {:ok, task} = TaskSupport.async_nolink(supervisor, fn -> :done end)
    assert {:ok, :done} = TaskSupport.await(task, 50)
  end

  test "shuts timed out tasks down", %{supervisor: supervisor} do
    assert {:ok, task} =
             TaskSupport.async_nolink(supervisor, fn ->
               Process.sleep(100)
               :slow
             end)

    assert {:error, :timeout} = TaskSupport.await(task, 1)
    refute Process.alive?(task.pid)
  end

  test "reports missing supervisors" do
    assert {:error, :noproc} =
             TaskSupport.async_nolink(:missing_task_supervisor, fn -> :ok end)
  end
end
