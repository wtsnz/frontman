defmodule Frontman.RuntimeTest do
  use ExUnit.Case, async: false
  import Plug.Test

  defmodule Gateway do
    def init(opts), do: Frontman.Proxy.init(opts)
    def call(conn, opts), do: Frontman.Proxy.call(conn, opts)
  end

  test "a stream holds its slot through completion while draining rejects new work" do
    start_supervised!({Frontman, options(StreamPool, 1, "stream") ++ [max_concurrency: 1]})
    eventually(fn -> length(Frontman.workers(StreamPool)) == 1 end)
    request = Task.async(fn -> proxy(StreamPool, "/stream") end)
    eventually(fn -> Frontman.status(StreamPool).in_flight == 1 end)
    assert %{status: 503} = proxy(StreamPool, "/")

    drain = Task.async(fn -> Frontman.drain(StreamPool, timeout: 2_000) end)
    eventually(fn -> Frontman.status(StreamPool).mode == :draining end)
    assert Task.yield(drain, 20) == nil
    assert %{status: 503} = proxy(StreamPool, "/")
    assert %{status: 200, resp_body: "first\nlast\n"} = Task.await(request)
    assert Task.await(drain) == :ok
    assert :ok = Frontman.resume(StreamPool)
    assert response(StreamPool) == "stream"
  end

  test "a real HTTP client disconnect frees its slot" do
    start_supervised!(
      {Frontman, options(DisconnectPool, 1, "disconnect") ++ [max_concurrency: 1]}
    )

    eventually(fn -> length(Frontman.workers(DisconnectPool)) == 1 end)

    gateway =
      start_supervised!(
        {Bandit,
         plug: {Gateway, [name: DisconnectPool]}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(gateway)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert {:ok, _headers} = :gen_tcp.recv(socket, 0, 2_000)
    assert Frontman.status(DisconnectPool).in_flight == 1
    :gen_tcp.close(socket)
    eventually(fn -> Frontman.status(DisconnectPool).in_flight == 0 end)
    assert response(DisconnectPool) == "disconnect"
  end

  test "explicit stop ends a stuck stream after the drain deadline and shuts down Node" do
    {:ok, runtime} = Frontman.start_link(options(StopPool, 1, "stop"))
    on_exit(fn -> if Process.alive?(runtime), do: Supervisor.stop(runtime) end)
    eventually(fn -> length(Frontman.workers(StopPool)) == 1 end)
    [worker] = Frontman.workers(StopPool)
    request = Task.async(fn -> proxy(StopPool, "/hang") end)
    eventually(fn -> Frontman.status(StopPool).in_flight == 1 end)

    eventually(fn ->
      {:ok, response} =
        Finch.build(:get, "http://127.0.0.1:#{worker.port}/__frontend/ready")
        |> Finch.request(Frontman.finch(StopPool))

      Jason.decode!(response.body)["active"] == 1
    end)

    # The fixture keeps /hang open until Node is asked to shut down.
    assert {:error, :timeout} = Frontman.stop(StopPool, timeout: 50)
    refute Process.alive?(runtime)
    eventually(fn -> not alive?(worker.node_pid) end)
    assert %Plug.Conn{} = Task.await(request)
  end

  test "independent pools serve requests, replace one crashed worker, and stop their processes" do
    start_supervised!({Frontman, options(FirstPool, 2, "first")})
    start_supervised!({Frontman, options(SecondPool, 1, "second")})
    eventually(fn -> length(Frontman.workers(FirstPool)) == 2 end)
    eventually(fn -> length(Frontman.workers(SecondPool)) == 1 end)

    first = Frontman.workers(FirstPool)
    [second] = Frontman.workers(SecondPool)
    assert response(FirstPool) == "first"
    assert response(SecondPool) == "second"

    [victim, survivor] = first
    assert {_, 0} = System.cmd("kill", ["-KILL", to_string(victim.node_pid)])

    eventually(fn ->
      workers = Frontman.workers(FirstPool)
      length(workers) == 2 and Enum.all?(workers, &(&1.node_pid != victim.node_pid))
    end)

    assert Enum.any?(Frontman.workers(FirstPool), &(&1.node_pid == survivor.node_pid))
    assert [^second] = Frontman.workers(SecondPool)
    assert response(FirstPool) == "first"

    pids = Enum.map(Frontman.workers(FirstPool), & &1.node_pid)
    stop_supervised!(FirstPool)
    eventually(fn -> Enum.all?(pids, &(not alive?(&1))) end)
    assert Frontman.workers(FirstPool) == []
    assert response(SecondPool) == "second"
    stop_supervised!(SecondPool)
    eventually(fn -> not alive?(second.node_pid) end)
  end

  test "rebuilds worker registration when the registry crashes" do
    start_supervised!({Frontman, options(RegistryPool, 1, "registry")})
    eventually(fn -> length(Frontman.workers(RegistryPool)) == 1 end)
    [old] = Frontman.workers(RegistryPool)
    Process.exit(Process.whereis(Frontman.registry(RegistryPool)), :kill)

    eventually(fn ->
      case Frontman.workers(RegistryPool) do
        [worker] -> worker.node_pid != old.node_pid
        _ -> false
      end
    end)

    eventually(fn -> not alive?(old.node_pid) end)
    assert response(RegistryPool) == "registry"
  end

  defp options(name, workers, label) do
    [
      name: name,
      workers: workers,
      executable: System.find_executable("node") || raise("Node is required for runtime tests"),
      args: ["server.mjs"],
      directory: Path.expand("support", __DIR__),
      env: [{"APP_LABEL", label}]
    ]
  end

  defp response(name) do
    conn = proxy(name, "/")
    assert conn.status == 200
    conn.resp_body
  end

  defp proxy(name, path),
    do: Frontman.Proxy.call(conn(:get, path), Frontman.Proxy.init(name: name))

  defp alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
