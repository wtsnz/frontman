# Run with MIX_ENV=test mix run examples/page_cache.exs from this library's directory.
# Uses an isolated pool of two Node fixtures whose /cached pages are marked cacheable.
Logger.configure(level: :warning)

defmodule PageCacheExample do
  def wait_until(fun, attempts \\ 100)
  def wait_until(_fun, 0), do: raise("demo condition timed out")

  def wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  def request(path) do
    conn =
      Plug.Test.conn(:get, path)
      |> Frontman.Proxy.call(Frontman.Proxy.init(name: DemoCachePool))

    status = conn |> Plug.Conn.get_resp_header("x-frontman-cache-status") |> List.first("none")
    {conn.status, status, conn.resp_body}
  end
end

{:ok, _pid} =
  Frontman.start_link(
    name: DemoCachePool,
    workers: 2,
    executable: System.find_executable("node") || raise("Node must be on PATH"),
    args: ["server.mjs"],
    directory: Path.expand("../test/support", __DIR__),
    env: [{"APP_LABEL", "demo"}],
    cache: [max_entries: 100]
  )

try do
  PageCacheExample.wait_until(fn -> length(Frontman.workers(DemoCachePool)) == 2 end)

  {200, "miss", first} = PageCacheExample.request("/cached")
  IO.puts("First request: rendered by Node, stored (#{first})")
  {200, "hit", ^first} = PageCacheExample.request("/cached")
  IO.puts("Second request: the same page, from the cache")
  {200, "none", _} = PageCacheExample.request("/")
  IO.puts("An unmarked page: rendered every time, never stored")

  {time, responses} =
    :timer.tc(fn ->
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> PageCacheExample.request("/cached-slow") end) end)
      |> Task.await_many()
    end)

  bodies = responses |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  IO.puts(
    "50 concurrent misses on a 300 ms page: #{length(bodies)} render, #{div(time, 1000)} ms"
  )

  {:ok, removed} = Frontman.invalidate(DemoCachePool, prefix: "/cached")
  IO.puts("Invalidated #{removed} pages")
  {200, "miss", _} = PageCacheExample.request("/cached")
  IO.puts("After invalidation: rendered again")

  IO.puts(
    "Cache: #{inspect(Map.take(Frontman.status(DemoCachePool).cache, [:entries, :hits, :misses, :stores, :invalidated]))}"
  )
after
  Frontman.stop(DemoCachePool)
end
