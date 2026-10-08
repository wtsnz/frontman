# Reference

## Pool options

Pass these to `{Frontman, opts}` or `Frontman.start_link/1`.

| Option | Default | Description |
| --- | --- | --- |
| `name` | required | Static module atom, unique per pool. Prefixes every process in the pool. |
| `executable` | required | Absolute path to the program, usually `node`. Run directly, without a shell. |
| `args` | required | Arguments, for example `[".output/server/index.mjs"]`. |
| `directory` | required | Working directory for the process. |
| `port` | | Loopback port of a server you run yourself, such as the Vite dev server. Replaces `executable`, `args`, `directory` and `workers`; see [External server](#external-server). |
| `workers` | `1` | Number of Node processes. Positive integer. |
| `max_concurrency` | `16` | Requests in flight per worker before admission rejects. Positive integer. |
| `env` | `[]` | Extra environment as `{"KEY", "value"}` string pairs. Added to the BEAM's environment. |
| `health_check_interval` | `2_000` | Milliseconds between the end of one probe and the start of the next. |
| `health_check_timeout` | `500` | Milliseconds allowed for each probe, end to end. |
| `health_check_failures` | `3` | Failed probes in a row before the worker replaces Node. |
| `startup_timeout` | `30_000` | Milliseconds Node has to pass its first probe. |
| `restart_backoff_min` | `250` | First backoff ceiling, in milliseconds. |
| `restart_backoff_max` | `30_000` | Largest backoff ceiling, in milliseconds. |
| `restart_backoff_reset_after` | `30_000` | Milliseconds a worker must stay ready before its attempt count resets. |
| `cache` | off | Keyword list of [page cache](#page-cache) options, or `true` for the defaults. `nil` or `false` leaves it off. Ignored, with a warning, alongside `port`. |

All timing options must be positive integers, and `restart_backoff_min` can't exceed
`restart_backoff_max`. Bad values raise `ArgumentError` at start.

### External server

With `port`, Frontman starts no process. It registers `127.0.0.1:<port>` as worker 1 and sends
requests there through the same admission and proxy. It never probes or restarts that server, so
the worker is always listed as ready. While nothing listens on the port, requests get `503`.
`max_concurrency` and `env` still apply; `env` has no effect without a process. The slot's phase
is `:external`.

Use it to put Phoenix in front of a development server, so cookies, hosts and backend routes
behave as they do in production. See [Setup](setup.md#8-development).

## Proxy options

Pass these to `Frontman.Proxy.init/1`, or straight to `Frontman.Proxy.call/2` from a wrapper
plug.

| Option | Default | Description |
| --- | --- | --- |
| `name` | required | The pool to send requests to. |
| `pass_through` | `[]` | Path prefixes left for later plugs. Plain prefix match, so include the trailing `/`. |
| `enabled` | `true` | When `false`, every request passes through untouched. |

Fixed behaviour:

| | |
| --- | --- |
| Request body limit | 8,000,000 bytes, then `413` |
| Finch pool timeout | 2 s |
| Receive timeout | 15 s |
| No slot available | `503`, `Retry-After: 2`, plain text body |
| `/__frontend/*` | `404`, never proxied |
| `X-Forwarded-Host` | Kept if the request has one, otherwise the `Host` header, port included |

`pass_through` is checked before the `/__frontend/` rule, so don't list that prefix.

## Functions

| Function | Returns |
| --- | --- |
| `Frontman.start_link(opts)` | `{:ok, pid}`. Starts a pool. `{Frontman, opts}` works as a child spec. |
| `Frontman.workers(name)` | Ready workers: `%{index, port, node_pid, pid, in_flight, state}`. `state` is `:ready` or `:draining`. `[]` if the pool isn't running. |
| `Frontman.status(name)` | `%{mode, in_flight, capacity, max_concurrency, workers, slots, cache}`, or `nil` if the pool isn't running. `cache` is `nil` without a page cache. |
| `Frontman.drain(name, timeout: ms)` | `:ok` when every lease has ended, `{:error, :timeout}`, or `{:error, :unavailable}`. Default timeout 5,000 ms. Leaves the pool closed. |
| `Frontman.resume(name)` | `:ok`, `{:error, :drain_in_progress}`, or `{:error, :unavailable}`. |
| `Frontman.stop(name, timeout: ms)` | Drains, stops the pool, and returns the drain result. `{:error, :unavailable}` if not running. |
| `Frontman.invalidate(name, opts)` | `{:ok, removed}` or `{:error, :unavailable}` when the pool has no cache. Takes `path:` or `prefix:`, and optionally `host:`. See [Invalidation](#invalidation). |
| `Frontman.checkout(name, excluded \\ [])` | `{:ok, worker}` with a `:lease`, or `{:error, :draining \| :unavailable \| :overloaded}`. The calling process owns the lease. |
| `Frontman.checkin(worker)` | `:ok`. Ends the lease. Safe to call twice. |

`checkout/2` and `checkin/1` are what the proxy uses. You only need them to send requests to
workers yourself.

Each entry in `status(name).slots` is `%{index, phase, port, node_pid, failures,
restart_attempt, next_delay}`, where `phase` is one of `:starting`, `:ready`, `:suspect`,
`:stopping`, `:backoff`, `:cleanup_failed`, or `:external` for an
[external server](#external-server).

`status(name).cache` is `%{entries, bytes, max_entries, max_bytes, hits, misses, stale, stores,
skips, evicted, invalidated, personalised}`. The counters start at zero when the pool starts. `misses` counts
requests that found no usable entry, including ones that then shared another request's render.

## Page cache

Set with the pool's `cache` option. See the [README](../README.md#page-cache) for how to mark
pages and keep them the same for every visitor.

| Option | Default | Description |
| --- | --- | --- |
| `max_entries` | `10_000` | Pages kept. Positive integer. |
| `max_bytes` | `64_000_000` | Bytes of bodies and stored headers kept. Positive integer. A page whose body and headers together exceed it isn't stored. |
| `max_entry_bytes` | `2_000_000`, or `max_bytes` if smaller | Largest body stored. A larger page is proxied and not stored. Can't exceed `max_bytes`. |
| `query` | `:all` | Which query parameters are part of the key: `:all`, `:ignore`, `{:only, names}` or `{:except, names}`, with names as strings. |
| `debug` | `false` | Check pages rendered for visitors with credentials, and log why marked pages weren't stored. See [Debug mode](#debug-mode). |

Bad values raise `ArgumentError` at start.

### Marker

Node opts a response in with `x-frontman-cache`, a comma-separated list of directives:

| Directive | |
| --- | --- |
| `public` | Required. |
| `max-age=N` | Seconds the page is fresh. Without it, the page stays until invalidated or evicted. |
| `stale-while-revalidate=N` | Seconds past `max-age` during which the old copy is served while one background render replaces it. Needs `max-age`. |

Frontman removes the header from every response while the pool has a cache, stored or not.
Without a cache the header passes through untouched.

A marked response is stored only if the request was a GET, the status is 200, and the response
has no `Set-Cookie`, no `Cache-Control: private` or `no-store`, no `Vary` other than
`Accept-Encoding`, no `Content-Encoding`, a body within `max_entry_bytes`, and arrived in full.

### Key

`{scheme, host, path, query}`:

- scheme from `X-Forwarded-Proto`, otherwise the connection's;
- host from `X-Forwarded-Host`, otherwise `Host`, lowercased and with any port;
- the raw request path;
- the query parameters the `query` option keeps, sorted by name, keeping repeated parameters
  in order.

### Response headers

| Header | Value |
| --- | --- |
| `x-frontman-cache-status` | `miss` on the render that stores a page, `hit` from memory, `stale` from memory while a refresh runs. Absent when the response wasn't from or for the cache. |
| `cache-control` | Node's. `no-cache` if Node sent none. |
| `etag` | Node's, or `W/"<hash>"` from the body's SHA-256. The render that stores a page has only Node's. |
| `age` | Seconds since the page was stored. |

Stored pages keep Node's other headers except `date`, `set-cookie`, `x-request-id`,
`content-length` and hop-by-hop headers. Phoenix's own `x-request-id` is kept.

A request whose `If-None-Match` matches the stored ETag, compared weakly, or is `*`, gets a
`304` with `cache-control`, `content-location`, `etag`, `expires`, `vary`, `age` and the status
header. On a cache fill, Frontman removes `If-None-Match` and `If-Modified-Since` before asking
Node, so Node returns the full page.

### Invalidation

```elixir
Frontman.invalidate(MyApp.SSR, path: "/pricing")
Frontman.invalidate(MyApp.SSR, host: "www.example.com", prefix: "/blog/")
```

`path` matches one path exactly and `prefix` every path that starts with it. Either matches
every query string and scheme. `host` is compared with the key's host, lowercased, port
included. Exactly one of `path` and `prefix` is required.

After `invalidate/2` returns, nothing rendered before the call is stored, and such a render
can't remove or mark a page either. The same holds across a cache restart. Waiters on such a
render render their own pages. The check is a single counter, so an invalidation also drops
renders of unrelated pages that were in flight at the time. They're rendered again on the next
request.

### Debug mode

With `debug: true`, a GET page that is about to be stored, and whose request carried `Cookie` or
`Authorization`, goes to Node once more as a background refresh does: without the visitor's
cookies, credentials or validators. The anonymous render is the one stored, and waiters get it.

Frontman compares the two bodies with every run of digits replaced by `0`, because TanStack
Start embeds timestamps in each render. If they still differ, it logs a warning with about
100 bytes of each body around the first difference, emits `[:frontman, :cache, :personalised]`
and counts it in `status(name).cache.personalised`. If the anonymous render can't be stored,
nothing is stored and Frontman logs why.

Debug mode also logs a warning whenever a response carries the marker but isn't stored for a
reason the app controls: an invalid marker, a method other than GET, `Set-Cookie`, a private
`Cache-Control`, `Vary`, `Content-Encoding`, or size.

The excerpts can contain whatever made the page personal, such as an email address. Use debug
mode in development builds and staging, not production.

### Fixed behaviour

| | |
| --- | --- |
| Wait for another request's render | Up to 15 s, then render alone |
| Waiters per page | 1,000. Past that, requests render through admission. |
| Background refresh | One per page at a time, without the visitor's `Cookie`, `Authorization` or validators |
| After a failed refresh | The stale copy stays; the next refresh starts no sooner than 1 s later |
| Refresh that isn't cacheable, apart from a 5xx or no response | Removes the page |
| Eviction | Past either bound, least recently used pages go until both are at 90% |
| Recency | Updated at most once a second per page |
| Uncacheable pages | Remembered, so later misses on them don't wait. The list is cleared when it reaches `max_entries`. |

## `mix frontman.package`

Builds the frontend with a pinned Node and copies Node and the build into `priv` for a release.
See [Setup](setup.md#9-ship-it-in-a-release). Configure it in `config :frontman, :package`.
Each option except `build` can also be given on the command line, for example
`--node-version 22.22.2` or `--frontend assets/app`.

| Option | Default | Description |
| --- | --- | --- |
| `node_version` | required | Exact Node version, such as `"22.22.2"`. |
| `frontend` | `"frontend"` | Directory with `package.json` and `package-lock.json`. |
| `build` | `["run", "build"]` | npm arguments that build the frontend. |
| `output` | `".output"` | The build's output directory, inside `frontend`. |
| `node_destination` | `"priv/node"` | Where Node goes. The binary is `bin/node` inside it. |
| `frontend_destination` | `"priv/frontend"` | Where the output directory is copied, keeping its name. |
| `node_mirror` | `"https://nodejs.org/dist"` | Base URL of Node releases, laid out like `nodejs.org/dist`, or a local directory. |

Paths are relative to the project root and must stay inside it.

Each run:

1. Picks Node's archive for the build machine: `linux-x64`, `linux-arm64`, `darwin-x64` or
   `darwin-arm64`. Other platforms, including musl Linux, fail.
2. Uses the cached `node-v<version>-<platform>.tar.gz` and `SHASUMS256.txt` if the archive still
   matches, otherwise downloads both through Mix's HTTP client, which verifies TLS against the
   system CA store and honours `HTTPS_PROXY` and `HEX_CACERTS_PATH`. A mismatch fails, and nothing
   unverified is cached.
3. Extracts the archive into `_build/<env>/frontman/` and runs `npm ci`, then npm with `build`, in
   `frontend`. That Node's `bin` comes first on `PATH`, so scripts that call `node`, `npm` or `npx`
   get the packaged versions.
4. Deletes `frontend/<output>` before building, and fails if the build doesn't write it again.
5. Replaces `node_destination` with `bin/node` and Node's `LICENSE`, and
   `frontend_destination/<output>` with a copy of the build.

The cache is `$FRONTMAN_CACHE_DIR`, or the user cache directory: `~/.cache/frontman` on Linux,
`~/Library/Caches/frontman` on macOS.

The checksum file comes from the same mirror as the archive, over HTTPS. It catches corrupted or
altered downloads, and a cached archive that changed on disk, but not a compromised mirror.
Frontman doesn't check the GPG signature on `SHASUMS256.txt`.

## Worker protocol

Any HTTP server can be a worker if it does the following.

**Reads these environment variables.** Frontman sets them on every start. Don't set them in
`env`.

| Variable | Value |
| --- | --- |
| `HOST` | `127.0.0.1` |
| `PORT` | A free port, new on each start |
| `FRONTEND_WORKER_TOKEN` | A random token, new on each start |
| `SERVER_SHUTDOWN_TIMEOUT` | `4` (seconds, read by Nitro) |

**Listens on `HOST:PORT`.**

**Answers `GET /__frontend/ready`** with status `200` and a JSON body:

```json
{ "token": "<FRONTEND_WORKER_TOKEN>", "pid": 12345 }
```

`token` must match exactly. `pid` must be a positive integer, the server's own OS PID. Answer
from the same event loop or thread that serves requests, so a hung server fails the probe.

**Exits on SIGTERM**, finishing requests in flight. Frontman waits six seconds before SIGKILL.

## Telemetry

Durations are in native time units. Convert with `System.convert_time_unit/3`. Every event's
metadata includes the pool `name`. Handlers run in the emitting process, so keep them fast.

### Requests

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:frontman, :request, :start]` | `in_flight` | `worker` (index) |
| `[:frontman, :request, :stop]` | `in_flight`, `duration` | `reason`: `:complete` or `:owner_down` |
| `[:frontman, :request, :rejected]` | `in_flight` | `reason`: `:overloaded`, `:unavailable` or `:draining` |

`in_flight` is the pool total after the event. A retried request emits `start` and `stop` for
each attempt.

### Pool

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:frontman, :pool, :drain]` | `in_flight` | |
| `[:frontman, :pool, :resume]` | | |

### Workers

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:frontman, :worker, :start]` | | `index`, `attempt` |
| `[:frontman, :worker, :ready]` | | `index` |
| `[:frontman, :worker, :unhealthy]` | `failures` | `index` |
| `[:frontman, :worker, :restart]` | `delay`, `ceiling` (ms) | `index`, `attempt`, `reason` |
| `[:frontman, :worker, :cleanup_failed]` | | `index`, `reason` |

Restart reasons are `{:node_exited, reason}`, `{:start_failed, reason}`, `:startup_timeout` and
`:health_check_failed`.

### Page cache

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:frontman, :cache, :hit]` | `age` (ms), `bytes` | `host`, `path`, `query` |
| `[:frontman, :cache, :stale]` | `age` (ms), `bytes` | `host`, `path`, `query` |
| `[:frontman, :cache, :miss]` | | `host`, `path`, `query` |
| `[:frontman, :cache, :store]` | `bytes` | `host`, `path`, `query` |
| `[:frontman, :cache, :skip]` | | `reason`, and `host`, `path`, `query` for GET and HEAD |
| `[:frontman, :cache, :evict]` | `count`, `bytes` | |
| `[:frontman, :cache, :invalidate]` | `count` | `host`, and `path` or `prefix` |
| `[:frontman, :cache, :personalised]` | | `host`, `path`, `query`. [Debug mode](#debug-mode) only. |

`hit`, `stale` and `miss` run in the request process. `skip` does too, except for
`:invalidated` and a `:too_large` page whose headers took it past `max_bytes`, which the cache
server emits along with `store`, `evict` and `invalidate`. Skip reasons:

| Reason | |
| --- | --- |
| `:not_marked` | A GET page without the marker. Expected for every personal page. |
| `:invalid_marker` | The marker had an unknown or malformed directive, or no `public`. |
| `:method` | A marked response to a method other than GET. |
| `:status`, `:error` | A status other than 200; `:error` for 5xx. |
| `:set_cookie`, `:private`, `:vary`, `:encoded` | The response had `Set-Cookie`, `Cache-Control: private` or `no-store`, `Vary` other than `Accept-Encoding`, or `Content-Encoding`. |
| `:too_large` | The body passed `max_entry_bytes`, or body and headers together passed `max_bytes`. |
| `:aborted` | The response stopped part-way. |
| `:unavailable` | No response from Node, such as a 503 from admission. |
| `:invalidated` | An invalidation ran while the page rendered. |

### OpenTelemetry

Each proxy attempt runs in a `frontend.proxy` span of kind `client`, with attributes
`frontend.worker` (index) and `http.response.status_code`. Transport errors set the span status
to error. The outgoing request carries the current context through the configured text map
propagator, usually `traceparent`.
