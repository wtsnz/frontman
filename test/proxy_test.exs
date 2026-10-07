defmodule Frontman.ProxyTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Frontman, as: Frontend
  alias Frontman.Proxy

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/stream"} = conn, _opts) do
      conn =
        conn
        |> prepend_resp_headers([
          {"set-cookie", "one=1; Path=/"},
          {"set-cookie", "two=2; Path=/"}
        ])
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, "first\n")
      {:ok, conn} = chunk(conn, "last\n")
      conn
    end

    def call(%{request_path: "/echo"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      headers =
        Map.new(
          ["content-type", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "host"],
          &{&1, conn |> get_req_header(&1) |> List.first()}
        )

      send_resp(
        conn,
        201,
        Jason.encode!(%{body: body, query: conn.query_string, headers: headers})
      )
    end

    def call(%{request_path: "/empty"} = conn, _opts), do: send_resp(conn, 304, "")
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    start_supervised!({Registry, keys: :duplicate, name: Frontend.registry(TestPool)})
    start_supervised!({Finch, name: Frontend.finch(TestPool)})
    start_supervised!({Frontman.Admission, name: TestPool, max_concurrency: 2})

    upstream =
      start_supervised!({Bandit, plug: Upstream, port: 0, ip: :loopback, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    %{port: port}
  end

  test "streams a page response with every cookie and without hop-by-hop headers", %{port: port} do
    register_worker(1, port)

    conn =
      conn(:get, "/stream")
      |> Proxy.call(
        Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
      )

    assert conn.halted
    assert conn.status == 200
    assert conn.resp_body == "first\nlast\n"
    assert get_resp_header(conn, "set-cookie") == ["one=1; Path=/", "two=2; Path=/"]
    assert get_resp_header(conn, "transfer-encoding") == []
    # Only the upstream's own value; the proxy adds no Plug default beside it.
    assert [_upstream] = get_resp_header(conn, "cache-control")
  end

  test "forwards the raw body, query and origin headers", %{port: port} do
    register_worker(1, port)

    conn =
      conn(:post, "/echo?page=2", ~s({"data":1}))
      |> Map.put(:host, "shop.example")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> Proxy.call(
        Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
      )

    assert conn.status == 201
    response = Jason.decode!(conn.resp_body)
    assert response["body"] == ~s({"data":1})
    assert response["query"] == "page=2"
    assert response["headers"]["content-type"] == "application/json"
    assert response["headers"]["x-forwarded-for"] == "203.0.113.9, 127.0.0.1"
    assert response["headers"]["x-forwarded-proto"] == "http"
    assert response["headers"]["x-forwarded-host"] == "shop.example"
  end

  test "forwards the Host header's port in x-forwarded-host", %{port: port} do
    register_worker(1, port)

    conn =
      conn(:get, "/echo")
      |> Map.put(:host, "app.localhost")
      # Plug.Test refuses a host request header; adapters such as Bandit keep it.
      |> Map.update!(:req_headers, &[{"host", "app.localhost:4000"} | &1])
      |> Proxy.call(Proxy.init(name: TestPool))

    assert Jason.decode!(conn.resp_body)["headers"]["x-forwarded-host"] == "app.localhost:4000"
  end

  test "sends a bodiless status without a chunked body", %{port: port} do
    register_worker(1, port)

    conn =
      conn(:get, "/empty")
      |> Proxy.call(
        Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
      )

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "leaves backend routes to Phoenix and hides worker probes", %{port: port} do
    register_worker(1, port)

    for path <- ["/rpc/run", "/health/ready", "/__demo/node", "/.muster/metrics"] do
      conn =
        conn(:post, path)
        |> Proxy.call(
          Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
        )

      refute conn.halted
      assert conn.state == :unset
    end

    assert %{status: 404, halted: true} =
             conn(:get, "/__frontend/ready")
             |> Proxy.call(
               Proxy.init(
                 name: TestPool,
                 pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"]
               )
             )
  end

  test "answers 503 with a retry hint when no worker is ready" do
    conn =
      conn(:get, "/")
      |> Proxy.call(
        Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
      )

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["2"]
    assert conn.resp_body =~ "temporarily unavailable"
  end

  test "rejects overload before reading a body and releases a rejected oversized body", %{
    port: port
  } do
    register_worker(1, port)
    {:ok, first} = Frontend.checkout(TestPool)
    {:ok, second} = Frontend.checkout(TestPool)
    body = String.duplicate("x", 8_000_001)
    opts = Proxy.init(name: TestPool)

    assert %{status: 503} = conn(:post, "/echo", body) |> Proxy.call(opts)
    Frontend.checkin(first)
    Frontend.checkin(second)
    assert %{status: 413} = conn(:post, "/echo", body) |> Proxy.call(opts)
    assert Frontend.status(TestPool).in_flight == 0
  end

  test "moves a refused request to another worker for any method", %{port: port} do
    register_worker(1, port)
    {:ok, live} = Frontend.checkout(TestPool)
    register_worker(2, closed_port())
    # The dead worker is idle, so least-busy selection tries it first.

    conn =
      conn(:post, "/echo", "payload")
      |> Proxy.call(
        Proxy.init(name: TestPool, pass_through: ["/rpc/", "/health/", "/__demo/", "/.muster/"])
      )

    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["body"] == "payload"
    assert Frontend.status(TestPool).in_flight == 1
    Frontend.checkin(live)
  end

  test "checks out the least busy worker and checks it back in", %{port: port} do
    register_worker(1, port)
    {:ok, busy} = Frontend.checkout(TestPool)
    register_worker(2, port)

    assert {:ok, %{index: 2} = worker} = Frontend.checkout(TestPool)
    assert Frontend.status(TestPool).in_flight == 2
    Frontend.checkin(worker)
    assert Frontend.status(TestPool).in_flight == 1
    Frontend.checkin(busy)
  end

  defp register_worker(index, port) do
    worker = %{
      index: index,
      port: port,
      node_pid: nil
    }

    start_supervised!(%{
      id: {:worker, index},
      start:
        {Agent, :start_link,
         [fn -> Registry.register(Frontend.registry(TestPool), :worker, worker) end]}
    })

    worker
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
