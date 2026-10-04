# Reference

## Pool options

Pass these to `{Frontman, opts}` or `Frontman.start_link/1`.

| Option | Default | Description |
| --- | --- | --- |
| `name` | required | Static module atom, unique per pool. Prefixes every process in the pool. |
| `executable` | required | Absolute path to the program, usually `node`. Run directly, without a shell. |
| `args` | required | Arguments, for example `[".output/server/index.mjs"]`. |
| `directory` | required | Working directory for the process. |
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

All timing options must be positive integers, and `restart_backoff_min` can't exceed
`restart_backoff_max`. Bad values raise `ArgumentError` at start.

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

`pass_through` is checked before the `/__frontend/` rule, so don't list that prefix.

## Functions

| Function | Returns |
| --- | --- |
| `Frontman.start_link(opts)` | `{:ok, pid}`. Starts a pool. `{Frontman, opts}` works as a child spec. |
| `Frontman.workers(name)` | Ready workers: `%{index, port, node_pid, pid, in_flight, state}`. `state` is `:ready` or `:draining`. `[]` if the pool isn't running. |
| `Frontman.status(name)` | `%{mode, in_flight, capacity, max_concurrency, workers, slots}`, or `nil` if the pool isn't running. |
| `Frontman.drain(name, timeout: ms)` | `:ok` when every lease has ended, `{:error, :timeout}`, or `{:error, :unavailable}`. Default timeout 5,000 ms. Leaves the pool closed. |
| `Frontman.resume(name)` | `:ok`, `{:error, :drain_in_progress}`, or `{:error, :unavailable}`. |
| `Frontman.stop(name, timeout: ms)` | Drains, stops the pool, and returns the drain result. `{:error, :unavailable}` if not running. |
| `Frontman.checkout(name, excluded \\ [])` | `{:ok, worker}` with a `:lease`, or `{:error, :draining \| :unavailable \| :overloaded}`. The calling process owns the lease. |
| `Frontman.checkin(worker)` | `:ok`. Ends the lease. Safe to call twice. |

`checkout/2` and `checkin/1` are what the proxy uses. You only need them to send requests to
workers yourself.

Each entry in `status(name).slots` is `%{index, phase, port, node_pid, failures,
restart_attempt, next_delay}`, where `phase` is one of `:starting`, `:ready`, `:suspect`,
`:stopping`, `:backoff` or `:cleanup_failed`.

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

### OpenTelemetry

Each proxy attempt runs in a `frontend.proxy` span of kind `client`, with attributes
`frontend.worker` (index) and `http.response.status_code`. Transport errors set the span status
to error. The outgoing request carries the current context through the configured text map
propagator, usually `traceparent`.
