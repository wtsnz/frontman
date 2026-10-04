defmodule Frontman.HealthTest do
  use ExUnit.Case, async: false
  alias Frontman, as: Runtime

  setup do
    id = make_ref()
    events = for event <- [:restart, :unhealthy, :ready], do: [:frontman, :worker, event]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def event(event, measurements, metadata, receiver),
    do: send(receiver, {List.last(event), measurements, metadata})

  test "a frozen worker is withdrawn and replaced while the other worker keeps serving" do
    root = start_supervised!({Runtime, options(FrozenPool, workers: 2)})
    eventually(fn -> length(Runtime.workers(FrozenPool)) == 2 end)
    [victim, survivor] = Runtime.workers(FrozenPool)
    signal(victim.node_pid, "STOP")

    try do
      eventually(fn ->
        Enum.all?(Runtime.workers(FrozenPool), &(&1.node_pid != victim.node_pid))
      end)

      for _ <- 1..10, do: assert(request(FrozenPool, "/").status == 200)
      assert Enum.any?(Runtime.workers(FrozenPool), &(&1.node_pid == survivor.node_pid))

      eventually(
        fn ->
          workers = Runtime.workers(FrozenPool)
          length(workers) == 2 and Enum.all?(workers, &(&1.node_pid != victim.node_pid))
        end,
        250
      )

      eventually(fn -> not alive?(victim.node_pid) end, 250)
      assert Process.whereis(FrozenPool) == root
      assert request(FrozenPool, "/").status == 200
      assert_receive {:restart, _, %{name: FrozenPool, reason: :health_check_failed}}
    after
      if alive?(victim.node_pid), do: signal(victim.node_pid, "CONT")
    end
  end

  test "an event-loop hang that cannot process SIGTERM is force-killed before replacement" do
    root = start_supervised!({Runtime, options(EventLoopPool, [])})
    eventually(fn -> length(Runtime.workers(EventLoopPool)) == 1 end)
    [worker] = Runtime.workers(EventLoopPool)
    assert request(EventLoopPool, "/freeze").status == 200

    try do
      eventually(
        fn ->
          case Runtime.workers(EventLoopPool) do
            [new] -> new.node_pid != worker.node_pid
            _ -> false
          end
        end,
        250
      )

      refute alive?(worker.node_pid)
      assert Process.whereis(EventLoopPool) == root
      assert request(EventLoopPool, "/").status == 200
    after
      if alive?(worker.node_pid), do: signal(worker.node_pid, "KILL")
    end
  end

  test "a transient failed probe recovers the same process without restarting it" do
    start_supervised!(
      {Runtime, options(TransientPool, health_check_interval: 200, health_check_failures: 4)}
    )

    eventually(fn -> length(Runtime.workers(TransientPool)) == 1 end)
    [worker] = Runtime.workers(TransientPool)
    signal(worker.node_pid, "STOP")

    try do
      assert_receive {:unhealthy, %{failures: 1}, %{name: TransientPool}}, 2_000
      signal(worker.node_pid, "CONT")
      eventually(fn -> length(Runtime.workers(TransientPool)) == 1 end)
      assert [same] = Runtime.workers(TransientPool)
      assert same.node_pid == worker.node_pid
      assert request(TransientPool, "/").status == 200
      refute_receive {:restart, _, %{name: TransientPool}}, 100
    after
      if alive?(worker.node_pid), do: signal(worker.node_pid, "CONT")
    end
  end

  test "immediate process failures back off with a cap without restarting the runtime" do
    root = start_supervised!({Runtime, options(CrashLoopPool, args: ["crash.mjs"])})

    for {ceiling, attempt} <- Enum.with_index([40, 80, 160, 160, 160, 160], 1) do
      assert_receive {:restart, %{ceiling: ^ceiling, delay: delay},
                      %{name: CrashLoopPool, attempt: ^attempt}},
                     3_000

      assert delay > div(ceiling, 2) and delay <= ceiling
      assert Process.whereis(CrashLoopPool) == root
    end

    assert Runtime.workers(CrashLoopPool) == []
    assert request(CrashLoopPool, "/").status == 503

    eventually(fn ->
      case Runtime.status(CrashLoopPool).slots do
        [%{restart_attempt: attempt}] -> attempt >= 6
        _ -> false
      end
    end)
  end

  test "sustained healthy probes reset backoff; replacement respects an existing drain" do
    start_supervised!({Runtime, options(ResetPool, restart_backoff_reset_after: 200)})
    eventually(fn -> length(Runtime.workers(ResetPool)) == 1 end)
    [worker] = Runtime.workers(ResetPool)
    signal(worker.node_pid, "KILL")
    assert_receive {:restart, %{ceiling: 40}, %{name: ResetPool, attempt: 1}}, 2_000

    eventually(fn ->
      case Runtime.status(ResetPool).slots do
        [%{phase: :ready, restart_attempt: 0, node_pid: pid}] -> pid != worker.node_pid
        _ -> false
      end
    end)

    assert :ok = Runtime.drain(ResetPool)
    [replacement] = Runtime.workers(ResetPool)
    signal(replacement.node_pid, "KILL")
    assert_receive {:restart, %{ceiling: 40}, %{name: ResetPool, attempt: 1}}, 2_000

    eventually(fn ->
      case Runtime.workers(ResetPool) do
        [%{node_pid: pid, state: :draining}] -> pid != replacement.node_pid
        _ -> false
      end
    end)

    assert request(ResetPool, "/").status == 503
    assert :ok = Runtime.resume(ResetPool)
    assert request(ResetPool, "/").status == 200
  end

  test "slow page streams and backend errors do not fail the independent health probe" do
    start_supervised!({Runtime, options(BusyPool, max_concurrency: 1)})
    eventually(fn -> length(Runtime.workers(BusyPool)) == 1 end)
    [worker] = Runtime.workers(BusyPool)
    stream = Task.async(fn -> request(BusyPool, "/stream") end)
    eventually(fn -> Runtime.status(BusyPool).in_flight == 1 end)
    assert %{status: 200, resp_body: "first\nlast\n"} = Task.await(stream)
    for _ <- 1..5, do: assert(request(BusyPool, "/backend-down").status == 503)
    assert [same] = Runtime.workers(BusyPool)
    assert same.node_pid == worker.node_pid
    refute_receive {:unhealthy, _, %{name: BusyPool}}
    refute_receive {:restart, _, %{name: BusyPool}}
  end

  test "a process that never completes its readiness handshake times out and backs off" do
    root =
      start_supervised!(
        {Runtime,
         options(UnreadyPool, env: [{"BAD_READINESS_TOKEN", "true"}], startup_timeout: 200)}
      )

    assert_receive {:restart, _, %{name: UnreadyPool, reason: :startup_timeout, attempt: 1}},
                   3_000

    assert Runtime.workers(UnreadyPool) == []
    assert Process.whereis(UnreadyPool) == root
  end

  defp options(name, overrides) do
    Keyword.merge(
      [
        name: name,
        workers: 1,
        executable: System.find_executable("node"),
        args: ["server.mjs"],
        directory: Path.expand("support", __DIR__),
        env: [{"APP_LABEL", "healthy"}],
        health_check_interval: 80,
        health_check_timeout: 100,
        health_check_failures: 2,
        restart_backoff_min: 40,
        restart_backoff_max: 160,
        startup_timeout: 2_000,
        restart_backoff_reset_after: 10_000
      ],
      overrides
    )
  end

  defp request(name, path),
    do:
      Plug.Test.conn(:get, path)
      |> Runtime.Proxy.call(Runtime.Proxy.init(name: name))

  defp signal(pid, signal) do
    assert {_, 0} = System.cmd("kill", ["-" <> signal, to_string(pid)], stderr_to_stdout: true)
  end

  defp alive?(pid),
    do: elem(System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true), 1) == 0

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(40)
      eventually(fun, attempts - 1)
    end
  end
end
