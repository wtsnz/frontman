defmodule Frontman.CacheTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Frontman.Proxy

  @pool CachePool
  @events for event <- [:hit, :miss, :stale, :store, :skip, :evict, :invalidate],
              do: [:frontman, :cache, event]

  # Reports every render to the test process. Bodies differ per render, so a repeated body
  # proves a response came from the cache.
  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:test], {:rendered, conn.request_path, conn.query_string})
      respond(conn, opts[:test])
    end

    defp respond(%{request_path: "/hold" <> _} = conn, test) do
      send(test, {:holding, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      marker = if conn.request_path == "/hold", do: [{"x-frontman-cache", "public"}], else: []
      page(conn, marker)
    end

    defp respond(%{request_path: "/cookie"} = conn, _test),
      do: page(conn, marked() ++ [{"set-cookie", "session=1; Path=/"}])

    defp respond(%{request_path: "/missing"} = conn, _test), do: page(conn, marked(), 404)
    defp respond(%{request_path: "/error"} = conn, _test), do: page(conn, marked(), 500)

    defp respond(%{request_path: "/private"} = conn, _test),
      do: page(conn, marked() ++ [{"cache-control", "private, max-age=60"}])

    defp respond(%{request_path: "/vary"} = conn, _test),
      do: page(conn, marked() ++ [{"vary", "Accept-Encoding, Cookie"}])

    defp respond(%{request_path: "/encoded"} = conn, _test),
      do: page(conn, marked() ++ [{"content-encoding", "gzip"}])

    defp respond(%{request_path: "/plain"} = conn, _test), do: page(conn, [])

    defp respond(%{request_path: "/invalid"} = conn, _test),
      do: page(conn, [{"x-frontman-cache", "max-age=60"}])

    defp respond(%{request_path: "/swr"} = conn, test) do
      send(test, {:cookie, conn |> get_req_header("cookie") |> List.first()})
      page(conn, marked("public, max-age=1, stale-while-revalidate=30"))
    end

    defp respond(%{request_path: "/short"} = conn, _test),
      do: page(conn, marked("public, max-age=1"))

    defp respond(%{request_path: "/tagged"} = conn, _test),
      do: page(conn, marked() ++ [{"etag", ~s("v1")}, {"cache-control", "public, max-age=5"}])

    defp respond(%{request_path: "/sized"} = conn, _test) do
      size = conn |> fetch_query_params() |> Map.get(:query_params) |> Map.get("n", "10")

      conn
      |> headers(marked())
      |> send_resp(200, String.duplicate("x", String.to_integer(size)))
    end

    defp respond(%{request_path: "/aborted"} = conn, _test) do
      conn = conn |> headers(marked()) |> send_chunked(200)
      {:ok, _conn} = chunk(conn, "partial")
      # Close the socket mid-body, as a crashing Node would.
      Process.exit(self(), :kill)
    end

    defp respond(%{request_path: "/streamed"} = conn, _test) do
      conn = conn |> headers(marked()) |> send_chunked(200)
      {:ok, conn} = chunk(conn, "first\n")
      {:ok, conn} = chunk(conn, "last\n")
      conn
    end

    defp respond(%{request_path: "/host"} = conn, _test) do
      host = conn |> get_req_header("x-forwarded-host") |> List.first()
      page(conn, marked(), 200, host)
    end

    defp respond(%{request_path: "/validators"} = conn, _test) do
      seen = conn |> get_req_header("if-none-match") |> List.first() |> inspect()
      page(conn, marked(), 200, seen)
    end

    defp respond(conn, _test), do: page(conn, marked())

    defp marked(value \\ "public"), do: [{"x-frontman-cache", value}]

    defp page(conn, headers, status \\ 200, body \\ nil) do
      body = body || "#{conn.request_path} #{System.unique_integer([:positive])}"

      conn
      |> headers([{"content-type", "text/html; charset=utf-8"} | headers])
      |> send_resp(status, body)
    end

    # Without Plug's default `cache-control: max-age=0, private, must-revalidate`, which would
    # make every page private.
    defp headers(conn, headers),
      do: conn |> delete_resp_header("cache-control") |> merge_resp_headers(headers)
  end

  setup context do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    start_supervised!({Registry, keys: :duplicate, name: Frontman.registry(@pool)})
    start_supervised!({Finch, name: Frontman.finch(@pool)})
    start_supervised!({Task.Supervisor, name: Frontman.tasks(@pool)})
    max_concurrency = Map.get(context, :max_concurrency, 16)
    start_supervised!({Frontman.Admission, name: @pool, max_concurrency: max_concurrency})

    config = Frontman.Cache.config!(Map.get(context, :cache, []))
    start_supervised!({Frontman.Cache, name: @pool, config: config})

    upstream =
      start_supervised!(
        {Bandit, plug: {Upstream, test: self()}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)

    start_supervised!(
      {Agent,
       fn ->
         Registry.register(Frontman.registry(@pool), :worker, %{
           index: 1,
           port: port,
           node_pid: nil
         })
       end}
    )

    handler = "cache-test-#{System.unique_integer()}"
    :telemetry.attach_many(handler, @events, &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    %{port: port}
  end

  describe "hits and misses" do
    test "stores a marked page on a miss and serves it on the next request" do
      first = get("/page")
      assert first.status == 200
      assert header(first, "x-frontman-cache-status") == "miss"
      assert header(first, "x-frontman-cache") == nil
      # Node set no cache-control, so browsers and CDNs revalidate rather than keep a copy.
      assert header(first, "cache-control") == "no-cache"
      assert renders("/page") == 1
      assert_receive {:telemetry, :miss, _, %{path: "/page", host: "www.example.com"}}
      assert_receive {:telemetry, :store, %{bytes: bytes}, %{path: "/page"}} when bytes > 0

      second = get("/page")
      assert second.status == 200
      assert second.resp_body == first.resp_body
      assert header(second, "x-frontman-cache-status") == "hit"
      assert header(second, "content-type") == "text/html; charset=utf-8"
      assert header(second, "cache-control") == "no-cache"
      assert "W/\"" <> _ = header(second, "etag")
      assert header(second, "age") == "0"
      assert header(second, "x-frontman-cache") == nil
      assert renders("/page") == 0
      assert_receive {:telemetry, :hit, %{age: _, bytes: _}, %{path: "/page"}}

      assert %{entries: 1, hits: 1, misses: 1, stores: 1} = stats()
    end

    test "keeps the request id Phoenix set and Node's own cache-control" do
      get("/tagged")

      conn =
        conn(:get, "/tagged")
        |> put_resp_header("x-request-id", "abc")
        |> Proxy.call(Proxy.init(name: @pool))

      assert header(conn, "x-frontman-cache-status") == "hit"
      assert header(conn, "x-request-id") == "abc"
      assert header(conn, "cache-control") == "public, max-age=5"
      assert header(conn, "etag") == ~s("v1")
    end

    test "stores a streamed page once the stream completes" do
      first = get("/streamed")
      assert first.resp_body == "first\nlast\n"
      assert header(get("/streamed"), "x-frontman-cache-status") == "hit"
      assert renders("/streamed") == 1
    end

    test "HEAD is served from a cached GET, and a HEAD miss stores nothing" do
      head = conn(:head, "/page") |> Proxy.call(Proxy.init(name: @pool))
      assert head.status == 200
      assert header(head, "x-frontman-cache-status") == nil
      assert renders("/page") == 1

      get("/page")
      assert renders("/page") == 1
      stats()

      head = conn(:head, "/page") |> Proxy.call(Proxy.init(name: @pool))
      assert head.status == 200
      assert header(head, "x-frontman-cache-status") == "hit"
      assert renders("/page") == 0
    end

    test "the host Node is told is part of the key, so a forged host can't poison others" do
      forged = get("/host", [{"x-forwarded-host", "evil.example"}])
      assert forged.resp_body == "evil.example"

      real = get("/host")
      assert real.resp_body == "www.example.com"
      assert header(real, "x-frontman-cache-status") == "miss"
      assert header(get("/host"), "x-frontman-cache-status") == "hit"
    end

    test "a cache fill asks Node for the full page, not a 304" do
      conn = get("/validators", [{"if-none-match", ~s("old")}])
      assert conn.status == 200
      assert conn.resp_body == "nil"
    end
  end

  describe "responses that are never stored" do
    test "Set-Cookie, non-200, private, Vary, encoded, unmarked and invalid markers" do
      for {path, reason} <- [
            {"/cookie", :set_cookie},
            {"/missing", :status},
            {"/error", :error},
            {"/private", :private},
            {"/vary", :vary},
            {"/encoded", :encoded},
            {"/plain", :not_marked},
            {"/invalid", :invalid_marker}
          ] do
        first = get(path)
        assert header(first, "x-frontman-cache-status") == nil, path
        assert header(first, "x-frontman-cache") == nil, path
        assert_receive {:telemetry, :skip, _, %{path: ^path, reason: ^reason}}

        get(path)
        assert renders(path) == 2, path
      end

      assert stats().entries == 0
    end

    test "methods other than GET and HEAD are never stored, and the marker never leaks" do
      for _ <- 1..2 do
        conn = conn(:post, "/page", "body") |> Proxy.call(Proxy.init(name: @pool))
        assert conn.status == 200
        assert header(conn, "x-frontman-cache") == nil
        assert_receive {:telemetry, :skip, _, %{reason: :method}}
      end

      assert renders("/page") == 2
      assert header(get("/page"), "x-frontman-cache-status") == "miss"
    end

    test "a stream that fails part-way is not stored" do
      capture_log(fn ->
        get("/aborted")
        get("/aborted")
      end)

      assert renders("/aborted") == 2
      assert_receive {:telemetry, :skip, _, %{path: "/aborted", reason: :aborted}}
      assert stats().entries == 0
    end

    @tag cache: [max_entry_bytes: 1_000]
    test "a page larger than max_entry_bytes is not stored" do
      assert byte_size(get("/sized?n=2000").resp_body) == 2_000
      assert_receive {:telemetry, :skip, _, %{reason: :too_large}}
      get("/sized?n=2000")
      assert renders("/sized") == 2
    end
  end

  describe "query strings" do
    test "by default every parameter is part of the key, in any order" do
      get("/page?b=2&a=1")
      assert header(get("/page?a=1&b=2"), "x-frontman-cache-status") == "hit"
      assert header(get("/page?a=1"), "x-frontman-cache-status") == "miss"
    end

    @tag cache: [query: :ignore]
    test ":ignore keys on the path alone" do
      get("/page?a=1")
      assert header(get("/page?b=2"), "x-frontman-cache-status") == "hit"
    end

    @tag cache: [query: {:only, ["page"]}]
    test "{:only, names} keys on the listed parameters" do
      get("/page?page=2&utm_source=a")
      assert header(get("/page?utm_source=b&page=2"), "x-frontman-cache-status") == "hit"
      assert header(get("/page?page=3"), "x-frontman-cache-status") == "miss"
    end

    @tag cache: [query: {:except, ["utm_source", "fbclid"]}]
    test "{:except, names} keys on everything but the listed parameters" do
      get("/page?id=1&utm_source=a")
      assert header(get("/page?fbclid=x&id=1"), "x-frontman-cache-status") == "hit"
      assert header(get("/page?id=2"), "x-frontman-cache-status") == "miss"
    end
  end

  describe "one render per page" do
    test "concurrent misses wait for one render and share it" do
      requests = for _ <- 1..20, do: Task.async(fn -> get("/hold") end)
      assert_receive {:holding, node}, 1_000
      # Nobody else reached Node while the first render is in progress.
      refute_receive {:holding, _}, 200
      send(node, :release)

      responses = Task.await_many(requests)
      assert responses |> Enum.map(& &1.resp_body) |> Enum.uniq() |> length() == 1
      assert Enum.all?(responses, &(&1.status == 200))
      assert Enum.count(responses, &(header(&1, "x-frontman-cache-status") == "miss")) == 1
      assert Enum.count(responses, &(header(&1, "x-frontman-cache-status") == "hit")) == 19
      assert renders("/hold") == 1
      assert %{stores: 1, misses: 20} = stats()
    end

    test "waiters render for themselves when the page can't be shared" do
      requests = for _ <- 1..5, do: Task.async(fn -> get("/hold-plain") end)
      assert_receive {:holding, first}, 1_000
      refute_receive {:holding, _}, 200
      send(first, :release)

      # The four waiters each go to Node once they hear the page isn't cacheable.
      others = for _ <- 1..4, do: held()
      Enum.each(others, &send(&1, :release))
      assert Enum.all?(Task.await_many(requests), &(&1.status == 200))
      assert renders("/hold-plain") == 5

      # Now known to be uncacheable, the page no longer makes anyone wait.
      requests = for _ <- 1..3, do: Task.async(fn -> get("/hold-plain") end)
      pids = for _ <- 1..3, do: held()
      Enum.each(pids, &send(&1, :release))
      Task.await_many(requests)
    end

    test "waiters render for themselves when the leader's process dies" do
      leader = Task.async(fn -> get("/hold") end)
      assert_receive {:holding, node}, 1_000
      waiters = for _ <- 1..3, do: Task.async(fn -> get("/hold") end)
      refute_receive {:holding, _}, 200

      Task.shutdown(leader, :brutal_kill)
      pids = for _ <- 1..3, do: held()
      Enum.each([node | pids], &send(&1, :release))
      assert Enum.all?(Task.await_many(waiters), &(&1.status == 200))
    end

    @tag max_concurrency: 1
    test "waiters don't bypass admission: a rejected leader sends them to the 503 path" do
      {:ok, lease} = Frontman.checkout(@pool)
      responses = for(_ <- 1..5, do: Task.async(fn -> get("/page") end)) |> Task.await_many()
      assert Enum.all?(responses, &(&1.status == 503))
      assert renders("/page") == 0
      Frontman.checkin(lease)
      assert get("/page").status == 200
    end
  end

  describe "freshness" do
    test "an entry past max-age is a miss" do
      first = get("/short")
      Process.sleep(1_100)
      second = get("/short")
      assert header(second, "x-frontman-cache-status") == "miss"
      assert second.resp_body != first.resp_body
      assert renders("/short") == 2
    end

    test "stale-while-revalidate serves the old copy while one refresh runs" do
      first = get("/swr", [{"cookie", "session=secret"}])
      assert renders("/swr") == 1
      Process.sleep(1_100)

      stale =
        for _ <- 1..5, do: get("/swr", [{"cookie", "session=secret"}])

      assert Enum.all?(stale, &(&1.resp_body == first.resp_body))
      assert Enum.all?(stale, &(header(&1, "x-frontman-cache-status") == "stale"))
      assert_receive {:telemetry, :stale, %{age: age}, %{path: "/swr"}} when age >= 1_000

      # One background render, without the visitor's cookie.
      assert_receive {:rendered, "/swr", ""}, 1_000
      assert_receive {:cookie, "session=secret"}
      assert_receive {:cookie, nil}
      refute_receive {:rendered, "/swr", _}, 200

      fresh = eventually(fn -> get("/swr") end, &(header(&1, "x-frontman-cache-status") == "hit"))
      assert fresh.resp_body != first.resp_body
    end
  end

  describe "invalidation" do
    test "removes a path's query variants, a prefix, and can be limited to a host" do
      for path <- ["/page?a=1", "/page?a=2", "/blog/one", "/blog/two", "/other"], do: get(path)
      get("/page", [{"x-forwarded-host", "Other.Example"}])
      assert stats().entries == 6

      assert {:ok, 2} = Frontman.invalidate(@pool, host: "www.example.com", path: "/page")
      assert_receive {:telemetry, :invalidate, %{count: 2}, %{path: "/page"}}
      assert header(get("/page?a=1"), "x-frontman-cache-status") == "miss"

      assert {:ok, 2} = Frontman.invalidate(@pool, prefix: "/blog/")
      assert {:ok, 2} = Frontman.invalidate(@pool, path: "/page")
      assert header(get("/other"), "x-frontman-cache-status") == "hit"
      assert stats().invalidated == 6
    end

    test "a render that started before an invalidation is not stored" do
      request = Task.async(fn -> get("/hold") end)
      assert_receive {:holding, node}, 1_000
      waiter = Task.async(fn -> get("/hold") end)
      refute_receive {:holding, _}, 100

      assert {:ok, 0} = Frontman.invalidate(@pool, path: "/hold")
      send(node, :release)
      assert Task.await(request).status == 200

      # The waiter isn't handed the old render either; it renders again.
      assert_receive {:holding, again}, 1_000
      send(again, :release)
      assert Task.await(waiter).status == 200
      assert_receive {:telemetry, :skip, _, %{reason: :invalidated}}
      assert stats().entries == 0
    end

    test "a render that outlives a cache restart doesn't store into the new cache" do
      request = Task.async(fn -> get("/hold") end)
      node = held()
      assert {:ok, 0} = Frontman.invalidate(@pool, path: "/hold")

      # The new cache counts invalidations from zero again; the old render must still lose.
      stop_supervised!(Frontman.Cache)
      start_supervised!({Frontman.Cache, name: @pool, config: Frontman.Cache.config!([])})
      send(node, :release)
      assert Task.await(request).status == 200
      assert stats().entries == 0
      assert header(get("/hold-plain"), "x-frontman-cache-status") == nil
    end

    test "rejects ambiguous options and reports a pool without a cache" do
      assert_raise ArgumentError, fn -> Frontman.invalidate(@pool, host: "x") end
      assert_raise ArgumentError, fn -> Frontman.invalidate(@pool, path: "/a", prefix: "/") end
      assert {:error, :unavailable} = Frontman.invalidate(NoSuchPool, path: "/")
    end
  end

  describe "conditional requests" do
    test "If-None-Match with the cached ETag gets a 304 from the cache" do
      get("/page")
      etag = header(get("/page"), "etag")

      for value <- [etag, String.replace_prefix(etag, "W/", ""), ~s("other", #{etag}), "*"] do
        conn = get("/page", [{"if-none-match", value}])
        assert conn.status == 304, value
        assert conn.resp_body == ""
        assert header(conn, "etag") == etag
        assert header(conn, "cache-control") == "no-cache"
        assert header(conn, "content-type") == nil
      end

      assert get("/page", [{"if-none-match", ~s("other")}]).status == 200
      assert renders("/page") == 1
    end

    test "Node's own ETag is used" do
      get("/tagged")
      assert get("/tagged", [{"if-none-match", ~s("v1")}]).status == 304
    end
  end

  describe "size bounds" do
    @tag cache: [max_entries: 3]
    test "past max_entries the least recently used entries go" do
      for i <- 1..3, do: get("/page?i=#{i}")
      Process.sleep(1_100)
      # Using the first entry makes it the most recently used.
      assert header(get("/page?i=1"), "x-frontman-cache-status") == "hit"
      get("/page?i=4")

      assert_receive {:telemetry, :evict, %{count: 2}, _}
      assert stats().entries == 2
      assert header(get("/page?i=1"), "x-frontman-cache-status") == "hit"
      assert header(get("/page?i=4"), "x-frontman-cache-status") == "hit"
      assert header(get("/page?i=2"), "x-frontman-cache-status") == "miss"
    end

    @tag cache: [max_bytes: 3_000, max_entry_bytes: 1_500]
    test "past max_bytes entries are evicted until the total fits" do
      for i <- 1..3, do: get("/sized?n=1000&i=#{i}")
      stats = stats()
      assert stats.entries == 2
      assert stats.bytes <= 3_000
      assert stats.evicted == 1
    end
  end

  @tag cache: [max_bytes: 1_000]
  test "max_bytes holds even when a body fits max_entry_bytes but its headers don't" do
    assert byte_size(get("/sized?n=1000").resp_body) == 1_000
    assert_receive {:telemetry, :skip, _, %{reason: :too_large}}
    assert %{entries: 0, bytes: 0} = stats()
  end

  test "a late refresh request for a page that is fresh again starts nothing" do
    get("/swr")
    assert renders("/swr") == 1
    stats()

    GenServer.cast(
      Frontman.cache(@pool),
      {:refresh, {"http", "www.example.com", "/swr", ""}, %{path: "/swr", headers: []}}
    )

    stats()
    refute_receive {:rendered, "/swr", _}, 200
  end

  describe "drain and shutdown" do
    test "a drain waits for a leader, waiters share its page, and hits keep being served" do
      get("/page")
      leader = Task.async(fn -> get("/hold") end)
      assert_receive {:holding, node}, 1_000
      waiters = for _ <- 1..3, do: Task.async(fn -> get("/hold") end)
      refute_receive {:holding, _}, 100

      drain = Task.async(fn -> Frontman.drain(@pool, timeout: 2_000) end)
      eventually(fn -> Frontman.status(@pool).mode end, &(&1 == :draining))
      assert header(get("/page"), "x-frontman-cache-status") == "hit"
      assert get("/new").status == 503

      send(node, :release)
      assert Task.await(drain) == :ok
      assert Task.await(leader).status == 200

      assert Enum.all?(
               Task.await_many(waiters),
               &(header(&1, "x-frontman-cache-status") == "hit")
             )
    end

    test "waiters render for themselves when the cache stops under them" do
      leader = Task.async(fn -> get("/hold") end)
      assert_receive {:holding, node}, 1_000
      waiters = for _ <- 1..3, do: Task.async(fn -> get("/hold") end)
      refute_receive {:holding, _}, 100

      stop_supervised!(Frontman.Cache)
      pids = for _ <- 1..3, do: held()
      Enum.each([node | pids], &send(&1, :release))
      assert Enum.all?(Task.await_many([leader | waiters]), &(&1.status == 200))

      # Without the cache, requests go to Node as before.
      assert header(get("/page"), "x-frontman-cache-status") == nil
      assert Frontman.status(@pool).cache == nil
    end
  end

  test "status reports the cache" do
    get("/page")
    stats()
    get("/page")

    stats()

    assert %{cache: %{entries: 1, hits: 1, misses: 1, max_entries: 10_000}} =
             Frontman.status(@pool)
  end

  test "rejects bad options" do
    assert_raise ArgumentError, fn -> Frontman.Cache.config!(max_entries: 0) end
    assert_raise ArgumentError, fn -> Frontman.Cache.config!(query: :some) end
    assert_raise ArgumentError, fn -> Frontman.Cache.config!(size: 1) end

    assert_raise ArgumentError, fn ->
      Frontman.Cache.config!(max_bytes: 10, max_entry_bytes: 20)
    end

    assert %{max_entry_bytes: 100} = Frontman.Cache.config!(max_bytes: 100)
  end

  describe "without a cache" do
    setup do
      stop_supervised!(Frontman.Cache)
      :ok
    end

    test "responses pass through untouched, marker included" do
      first = get("/page")
      assert header(first, "x-frontman-cache") == "public"
      assert header(first, "x-frontman-cache-status") == nil
      assert header(first, "etag") == nil
      assert get("/page").resp_body != first.resp_body
      assert renders("/page") == 2
      assert Frontman.status(@pool).cache == nil
      refute_received {:telemetry, _, _, _}
    end

    test "conditional headers still reach Node" do
      assert get("/validators", [{"if-none-match", ~s("old")}]).resp_body == ~s("\\"old\\"")
    end
  end

  test "a pool that proxies to an external server, such as Vite, never caches" do
    log =
      capture_log(fn ->
        start_supervised!({Frontman, name: ExternalPool, port: closed_port(), cache: []})
      end)

    assert log =~ "ignores cache"
    assert Frontman.status(ExternalPool).cache == nil
  end

  def forward(event, measurements, metadata, test),
    do: send(test, {:telemetry, List.last(event), measurements, metadata})

  defp get(path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> Proxy.call(Proxy.init(name: @pool))
  end

  # The pid of the next upstream request that is waiting for `:release`.
  defp held do
    receive do
      {:holding, pid} -> pid
    after
      1_000 -> flunk("no request reached the upstream")
    end
  end

  # Stores are casts. Reading stats through the server waits for any already sent.
  defp stats do
    :sys.get_state(Frontman.cache(@pool))
    Frontman.Cache.stats(@pool)
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  # Counts and clears the renders of `path` reported so far.
  defp renders(path, count \\ 0) do
    receive do
      {:rendered, ^path, _query} -> renders(path, count + 1)
    after
      0 -> count
    end
  end

  defp eventually(fun, check, attempts \\ 40) do
    result = fun.()

    cond do
      check.(result) -> result
      attempts == 0 -> flunk("condition not met: #{inspect(result)}")
      true -> Process.sleep(25) && eventually(fun, check, attempts - 1)
    end
  end

  defp capture_log(fun), do: ExUnit.CaptureLog.capture_log(fun)

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
