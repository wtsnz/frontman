defmodule Frontman.AdmissionTest do
  use ExUnit.Case, async: false
  alias Frontman, as: Runtime

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Runtime.registry(AdmissionPool)})
    start_supervised!({Runtime.Admission, name: AdmissionPool, max_concurrency: 2})

    start_supervised!(
      {Agent,
       fn ->
         Registry.register(Runtime.registry(AdmissionPool), :worker, %{
           index: 1,
           port: 1,
           node_pid: nil
         })
       end}
    )

    :ok
  end

  test "simultaneous callers cannot exceed capacity and release is idempotent" do
    parent = self()

    callers =
      for _ <- 1..40 do
        spawn(fn ->
          result = Runtime.checkout(AdmissionPool)
          send(parent, {:reserved, self(), result})

          receive do
            :finish ->
              case result do
                {:ok, lease} ->
                  Runtime.checkin(lease)
                  Runtime.checkin(lease)

                _ ->
                  :ok
              end
          end
        end)
      end

    results =
      for _ <- callers do
        assert_receive {:reserved, _pid, result}, 2_000
        result
      end

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :overloaded})) == 38
    assert Runtime.status(AdmissionPool).in_flight == 2
    for pid <- callers, do: send(pid, :finish)
    eventually(fn -> Runtime.status(AdmissionPool).in_flight == 0 end)
  end

  test "a killed reservation owner releases capacity without checkin" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _lease} = Runtime.checkout(AdmissionPool)
        send(parent, :reserved)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :reserved
    Process.exit(owner, :kill)
    eventually(fn -> Runtime.status(AdmissionPool).in_flight == 0 end)
  end

  test "drain closes admission until every reservation finishes; resume is explicit" do
    {:ok, lease} = Runtime.checkout(AdmissionPool)
    drain = Task.async(fn -> Runtime.drain(AdmissionPool, timeout: 1_000) end)
    eventually(fn -> Runtime.status(AdmissionPool).mode == :draining end)
    assert {:error, :draining} = Runtime.checkout(AdmissionPool)
    assert {:error, :drain_in_progress} = Runtime.resume(AdmissionPool)
    assert Task.yield(drain, 20) == nil
    Runtime.checkin(lease)
    assert Task.await(drain) == :ok
    assert {:error, :draining} = Runtime.checkout(AdmissionPool)
    assert :ok = Runtime.resume(AdmissionPool)
    assert {:ok, lease} = Runtime.checkout(AdmissionPool)
    Runtime.checkin(lease)
  end

  test "drain timeout is bounded and does not silently reopen admission" do
    {:ok, lease} = Runtime.checkout(AdmissionPool)
    assert {:error, :timeout} = Runtime.drain(AdmissionPool, timeout: 20)
    assert Runtime.status(AdmissionPool).mode == :draining
    assert {:error, :draining} = Runtime.checkout(AdmissionPool)
    Runtime.checkin(lease)
    assert :ok = Runtime.drain(AdmissionPool, timeout: 0)
    assert :ok = Runtime.resume(AdmissionPool)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
