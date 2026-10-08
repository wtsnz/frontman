# Operations

## Check the pool

From a remote console (`bin/my_app remote`):

```elixir
Frontman.status(MyApp.SSR)
# %{
#   mode: :ready,
#   in_flight: 3,
#   capacity: 32,
#   max_concurrency: 16,
#   workers: [%{index: 1, port: 41231, node_pid: 9120, pid: #PID<0.812.0>, in_flight: 2, state: :ready}, ...],
#   slots: [%{index: 1, phase: :ready, port: 41231, node_pid: 9120, failures: 0, restart_attempt: 0, next_delay: nil}, ...],
#   cache: %{entries: 412, bytes: 18_204_112, max_entries: 10_000, max_bytes: 64_000_000, hits: 90_211, misses: 1_532, ...}
# }
```

`workers` lists only workers that passed their probe. `slots` lists every configured worker,
including ones that are starting, backing off or stuck in `cleanup_failed`. When a worker is
missing from `workers`, look at its slot. `status/1` returns `nil` while the pool is stopped or
starting.

`cache` is `nil` for a pool without a page cache.

## Page cache

A node starts with an empty cache, so a deploy serves pages built by the new release. Expect a
burst of misses after each start. Each page renders once, however many requests arrive for it.

Size it from the pages you mark. `bytes` in `status/1` divided by `entries` is the average stored
page. Without `max-age`, a page stays until invalidated or evicted, so invalidate when the data
behind it changes. Invalidation is local to the node; see the
[README](../README.md#invalidate) for broadcasting it.

From a remote console:

```elixir
Frontman.invalidate(MyApp.SSR, prefix: "/")   # empty this node's cache
```

## Deploy with a drain

The safe order for replacing a release is:

1. Start the new release and wait for its health check.
2. Point the load balancer at the new release.
3. Drain the old release's pool, so in-flight pages finish.
4. Stop the old release.

```elixir
# On the old release, after traffic has moved
:ok = Frontman.drain(MyApp.SSR, timeout: 10_000)
```

`drain/2` returns `:ok` once every request in flight has finished, or `{:error, :timeout}` at the
deadline. Either way, the pool stays closed. New page requests get 503 until you call
`Frontman.resume/1`. Backend routes and static assets keep working throughout, so a client
that has already loaded a page can carry on using the API.

Drain doesn't tell your load balancer anything. If you drain before moving traffic, users get
503s. Make sure your health check counts only `state: :ready` workers (see
[Setup](setup.md#7-report-readiness)), so a drained release reports itself unhealthy.

To undo a drain:

```elixir
Frontman.resume(MyApp.SSR)
# :ok, or {:error, :drain_in_progress} while another drain call is still waiting
```

### Stopping

For a pool you started yourself, outside a supervisor:

```elixir
Frontman.stop(MyApp.SSR, timeout: 5_000)
```

This drains, then stops the pool even if the drain timed out, and returns the drain result.
Each worker then gets up to eight seconds to stop its Node process.

Don't call `stop/2` on a pool your application supervisor owns. The supervisor will restart it.
Drain it, then let the release shut down, or terminate the child through its supervisor.

A normal release shutdown stops the pool through OTP without draining first. Node gets SIGTERM
and `SERVER_SHUTDOWN_TIMEOUT=4`, so Nitro closes its listener and gives open connections four
seconds. Requests still going after that are cut off.

## Tuning

| Setting | Default | Notes |
| --- | --- | --- |
| `workers` | 1 | One per CPU is a reasonable start. Each worker is a full Node process, so memory sets the ceiling. |
| `max_concurrency` | 16 | Per worker. Past this, requests get 503 rather than queueing. Measure under your own SSR load. |
| `health_check_timeout` | 500 ms | Raise it if your event loop has long synchronous stretches during SSR. |
| `cache` `max_entries`, `max_bytes` | 10,000, 64 MB | Per node, in the BEAM's memory. Raise them if `evicted` climbs while the same pages keep missing. |
| `cache` `query` | `:all` | Leave tracking parameters out with `{:except, names}`, so links from campaigns share one entry. |
| `health_check_failures` | 3 | With the defaults, a hung worker stops getting requests within about 2.5 s, and Frontman starts replacing it within about 7.5 s. |

The full list is in [Reference](reference.md#pool-options). None of the defaults come from load
testing. Treat them as starting values.

Frontman doesn't cap total connections. Set connection limits and body read timeouts on your
HTTP server (Bandit or Cowboy) as well.

## Telemetry worth watching

All events are listed in [Reference](reference.md#telemetry). These are the ones to graph or
alert on:

| Event | Watch for |
| --- | --- |
| `[:frontman, :request, :rejected]` with `reason: :overloaded` | Sustained rejections mean you need more workers or a higher `max_concurrency` |
| `[:frontman, :request, :rejected]` with `reason: :unavailable` | No ready workers. Pages are down. |
| `[:frontman, :worker, :restart]` | A climbing `attempt` means a worker can't stay up, often a broken build or bad environment |
| `[:frontman, :worker, :unhealthy]` | Probe failures. Frequent ones without restarts suggest a slow event loop |
| `[:frontman, :worker, :cleanup_failed]` | Always alert. That slot serves nothing until the worker restarts |
| `[:frontman, :request, :stop]` `duration` | SSR latency as seen by Phoenix, including streaming |
| `[:frontman, :cache, :hit]` against `:miss` | The share of marked pages served from memory |
| `[:frontman, :cache, :skip]` by `reason` | `:not_marked` is normal for personal pages. `:set_cookie`, `:private` or `:invalid_marker` on a page you marked means it isn't being cached. |
| `[:frontman, :cache, :evict]` | Steady eviction means the cache is too small for the pages you mark, or clients are making up query strings |

The proxy also opens a `frontend.proxy` OpenTelemetry span for each attempt, with the worker
index and response status. Frontman depends only on the OpenTelemetry API. Configure the SDK and
exporter in your application to see the spans.

Node's stdout and stderr go to Logger at `:info`, prefixed with `frontend[N]`.

## Failure modes

| What happens | What users see | What Frontman does |
| --- | --- | --- |
| Node crashes | New requests move to another worker. In-flight ones fail, unless they're GET or HEAD with no headers sent yet. | Withdraws the worker, backs off, starts a new Node |
| Node hangs | Requests on that worker wait, up to the 15 s receive timeout | First failed probe withdraws it. Replaced after `health_check_failures` |
| Build is broken | 503 for pages while no worker is ready | Retries with backoff up to `restart_backoff_max` (30 s by default) |
| Every worker is busy | 503 with `Retry-After: 2` | Nothing to recover. Admission resumes as requests finish. |
| A registry, Finch pool or admission server crashes | 503 for pages briefly | `rest_for_one` restarts it and every worker after it |
| Node won't exit | That slot stays empty | `cleanup_failed`. No replacement until the worker process restarts |
| No worker is ready, or the pool is draining | Cached pages, including stale ones within `stale-while-revalidate`, keep working. Misses get 503. | Refreshes fail and are retried a second later |
| The cache server crashes | Every page misses once | Restarts empty. Node and in-flight requests are unaffected. |

## Limits

- The pool size is fixed at boot. There's no autoscaling, and no per-worker memory limit.
- Request bodies are buffered, up to 8 MB, and over that limit get 413. Responses stream.
- WebSocket upgrades and response trailers are not proxied.
- Once response headers have gone to the client, a failure can't be retried or turned into a
  503. The client gets a truncated response.
- The proxy uses a 2 s pool timeout and a 15 s receive timeout. Neither is configurable yet.
- There's a short race between picking a free port and Node binding it. The readiness token
  stops a wrong process from registering, but can't prevent the race.
- Cleanup signals only the direct child of the MuonTrap wrapper. There's no cgroup containment,
  so Node's own children, or Node itself after the wrapper is killed, can be orphaned.
- Phoenix is on the page path. If Phoenix is down, pages are down.
- Drain isn't wired into any deploy tool. Your deploy script calls it.
- The page cache is in memory on each node. Nodes don't share pages or invalidations.
- A page larger than `max_entry_bytes`, or a request with a made-up query string, still costs
  a render each time. Leave unknown parameters out of the key with the `query` option.
