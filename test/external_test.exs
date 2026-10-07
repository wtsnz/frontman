defmodule Frontman.ExternalTest do
  use ExUnit.Case, async: false
  import Plug.Test

  defmodule DevServer do
    import Plug.Conn

    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, "dev #{conn.request_path}")
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    :ok
  end

  test "sends requests to a server running outside Frontman" do
    server =
      start_supervised!({Bandit, plug: DevServer, port: 0, ip: :loopback, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    start_supervised!({Frontman, name: ExternalPool, port: port})

    assert [%{index: 1, port: ^port, node_pid: nil, state: :ready}] =
             Frontman.workers(ExternalPool)

    assert [%{phase: :external, port: ^port}] = Frontman.status(ExternalPool).slots
    assert %{status: 200, resp_body: "dev /src/main.tsx"} = proxy(ExternalPool, "/src/main.tsx")
    assert Frontman.status(ExternalPool).in_flight == 0
  end

  test "answers 503 while the external server isn't listening" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Frontman, name: ClosedPool, port: port})

    assert %{status: 503} = proxy(ClosedPool, "/")
    # The server is still registered, so the next request tries it again.
    assert [%{port: ^port}] = Frontman.workers(ClosedPool)
  end

  test "rejects a port combined with options for a managed pool" do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: "executable can't be combined with port"}, _}} =
             Frontman.start_link(name: MixedPool, port: 5173, executable: "node")

    assert {:error, {%ArgumentError{}, _}} = Frontman.start_link(name: BadPortPool, port: 0)
  end

  defp proxy(name, path),
    do: Frontman.Proxy.call(conn(:get, path), Frontman.Proxy.init(name: name))
end
