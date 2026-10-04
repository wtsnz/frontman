# Frontman

An OTP-supervised pool of HTTP frontend processes with a streaming Plug proxy. Extracted from
the TanStack Start catalogue example. It has no Phoenix, Ash, TanStack or Muster dependency;
workers must implement the small HTTP readiness protocol below. OpenTelemetry's API preserves
proxy spans and trace propagation; a tracing SDK/exporter is configured by the host application.

Experimental. The API may change before a Hex release. Available as a Git dependency;
no package has been published to Hex.

## Install

Add the Git dependency to your application's `mix.exs`:

```elixir
{:frontman, github: "wtsnz/frontman", branch: "main"}
```

Run `mix deps.get` and commit `mix.lock`. Mix locks the dependency to a commit. Use `ref: "<commit SHA>"` instead of `branch: "main"` to pin that commit in `mix.exs` too.
Use `mix deps.update frontman` when you want to adopt a newer revision.

For local development alongside an application:

```elixir
{:frontman, path: "../frontman"}
```

The host application builds and supplies the frontend bundle and Node executable.
This dependency manages processes and forwards HTTP requests. It does not generate an
Ash TypeScript API, build TanStack Start, or configure deployment infrastructure.

## Start a pool

Add this child after any backend HTTP listener that SSR needs:

```elixir
{Frontman,
 name: MyApp.SSR,
 executable: "/usr/local/bin/node",
 args: [".output/server/index.mjs"],
 directory: "/app/frontend",
 workers: 2,
 max_concurrency: 16,
 env: [{"BACKEND_URL", "http://127.0.0.1:4000"}]}
```

`name` must be a unique, static module atom. `executable`, `args` and `directory` are required.
`workers` defaults to one and must be positive. `max_concurrency` defaults to 16 per worker and must also be positive; tune it with SSR load measurements. `env` defaults to `[]` and contains string pairs.
The executable starts directly through MuonTrap, without a shell. Environment variables from
the parent process are inherited; the host application is responsible for environment policy.
Pools have separate registries, data and health HTTP clients, task supervisors, admission coordinators and worker supervisors. Start multiple pools with
different names. If a backend chooses a port at runtime, construct these options in an application
child's `start_link/1`, after that backend starts; the library does not discover Phoenix listeners.

## Route requests

Place the proxy before `Plug.Parsers`, after any static-asset Plug:

```elixir
plug Frontman.Proxy,
  name: MyApp.SSR,
  pass_through: ["/rpc/", "/webhooks/", "/health/"]
```

Prefix matches pass untouched to subsequent plugs. All other requests go to a ready worker.
The `pass_through` default is empty; the application owns its route policy. Set `enabled: false`
to pass all requests through, for example when running the frontend separately. Options supplied
through an endpoint's `plug` declaration are initialized at compile time; use a wrapper Plug
when the enabled flag must be read at runtime.

`/__frontend/*` is private and returns 404 when the proxy is enabled. Do not include that prefix
in `pass_through`. No ready workers produces a 503 with `Retry-After: 2`. This does not prevent
backend routes or static assets from being served. Responses stream, preserving repeated
`Set-Cookie` headers. Request bodies are buffered with an 8 MB limit. WebSocket upgrades and
response trailers are not supported.

The proxy uses a 2-second HTTP pool timeout and a 15-second receive timeout. Refused connections
can retry another worker; closed connections retry only GET/HEAD before response headers have
been sent. Once streaming starts, a failed response cannot be replayed.

## Worker protocol

The runtime assigns `HOST=127.0.0.1`, `PORT`, `FRONTEND_WORKER_TOKEN` and
`SERVER_SHUTDOWN_TIMEOUT=4`; do not set these keys in `env`. The worker must bind to that address
and answer `GET /__frontend/ready` with status 200 and:

```json
{"token": "the FRONTEND_WORKER_TOKEN value", "pid": 12345}
```

`pid` is the frontend process's OS PID, not MuonTrap's wrapper PID. For a TanStack Start server
entry, add this before calling the normal Start handler:

```typescript
if (new URL(request.url).pathname === "/__frontend/ready") {
  return Response.json({
    token: process.env.FRONTEND_WORKER_TOKEN,
    pid: process.pid,
  });
}
```

An exact token match registers a worker as ready. Startup probes run every 50 ms, with a
500 ms receive timeout, for up to 30 seconds. `Frontman.workers(MyApp.SSR)` returns ready
workers with `index`, `port`, `node_pid`, BEAM `pid` and `in_flight` count and `state` (`:ready` or `:draining`). An empty
list also covers a pool that is stopped or starting. The application combines this with its
own database readiness; the library does not mount a public health endpoint.

## Capacity and draining

Admission is atomic across callers. Each request reserves a worker slot before its body is
read and keeps it until streaming finishes or is cancelled. There is no capacity-waiting queue:
full pools immediately return 503 with `Retry-After: 2`. The small coordinator only manages
reservations; HTTP bodies do not pass through it. Request-process monitors release abandoned
reservations, and explicit release is idempotent. Admission calls expire rather than granting
work that has waited too long in the coordinator mailbox. This is not a global socket limit:
configure the HTTP server's connection limits and body-read timeouts as well.

```elixir
Frontman.status(MyApp.SSR)
# %{mode: :ready, in_flight: 0, capacity: 32, max_concurrency: 16, workers: [...]}
Frontman.drain(MyApp.SSR, timeout: 5_000)
# :ok once all reservations finish; {:error, :timeout} if the deadline expires
Frontman.resume(MyApp.SSR)
```

Drain closes admission for the entire pool, including replacement workers, and leaves it closed
on success or timeout. It does not terminate processes or cancel active requests. Resume is
explicit and is rejected while another drain call is still waiting. Backend passthrough and
static assets remain available. `workers/1` includes draining workers, so public readiness
must count only workers whose `state` is `:ready`; saturation alone need not fail readiness.

For a directly started runtime, `Frontman.stop(name, timeout: 5_000)` drains, then stops
its supervisor even if the drain timed out. It returns the drain outcome. The drain deadline
is followed by the existing per-worker shutdown allowance, not an overall stop deadline.
For a runtime owned by your application supervisor, first drain it, then terminate its child
through that supervisor or stop the release. Calling `stop/2` on a permanent supervised child
would cause its parent to restart it. Abrupt supervisor shutdown still uses the ordinary
shutdown path without an admission drain. Muster's cutover hooks are not wired automatically;
switch traffic first, drain the old release, then stop it.

Telemetry events are `[:frontman, :request, :start | :stop | :rejected]` and
`[:frontman, :pool, :drain | :resume]`. Request measurements include total `in_flight`;
stop adds `duration` in native time units. Metadata includes the pool `name`, rejection/release
`reason`, or selected worker index for start. Telemetry handlers must return quickly.

Try the isolated demonstration (Node on PATH; no database required):

```sh
MIX_ENV=test mix run examples/admission.exs
```

Two streams fill a two-worker pool with one slot each. The demo shows overload rejection,
completion of the existing streams during drain, and successful requests after resume.

## Lifecycle and limits

Each Elixir worker owns its Node process across failures. Expected Node exits, failed startups
and health failures use delayed retries inside that worker; they do not consume the OTP
supervisor's restart budget. Unexpected Elixir-worker crashes still use OTP supervision, with
five restarts per configured worker within ten seconds. Repeated internal failures can still
propagate to the parent. Losing registry, HTTP-client, admission or task infrastructure restarts
dependent workers. There is no runtime scaling.

Cleanup identifies the wrapper's direct child through `ps`, sends SIGTERM and SIGCONT (so a
paused child can terminate), and waits up to six seconds before SIGKILL. Parent ownership is
checked before signaling. Cleanup then waits for exit before stopping the wrapper or starting
a replacement. If ownership or cleanup cannot be confirmed, the slot stays `:cleanup_failed`
and emits an event instead of starting another process. Worker shutdown allows eight seconds.
Frontends should handle SIGTERM and drain requests within that budget. The explicit drain operation must be coordinated with the external load balancer by the host application.

Readiness is checked at startup and throughout the process lifetime (see below).
Port allocation releases a temporary socket before the child binds; the token prevents a wrong
process from registering, but cannot remove that allocation race. Killing MuonTrap's wrapper
can orphan its child on systems without process-group/cgroup containment. These limits predate
the extraction and remain work before broader production adoption.

## Health checks and restart backoff

After startup, each worker probes the token-bearing Node readiness endpoint on a separate Finch
client. Probe tasks have a wall-clock deadline and never block the worker owner. They do not use
SSR admission slots or query Phoenix/Postgres. A slow backend response does not by itself trigger
a Node restart. The endpoint must answer from the Node event loop, not from another process.

The first failed probe withdraws a worker from new requests. A successful subsequent probe restores
it without restart. Consecutive failures reach the configured threshold and initiate cleanup,
followed by backoff and replacement. Existing requests to an unresponsive worker may fail or wait
until the proxy timeout; the watchdog does not guarantee uninterrupted in-flight responses.

Pool options (milliseconds except the failure count):

| Option | Default | Purpose |
| --- | --- | --- |
| `health_check_interval` | 2,000 | Delay after a health probe completes |
| `health_check_timeout` | 500 | Total deadline for each probe |
| `health_check_failures` | 3 | Consecutive failures before replacement |
| `startup_timeout` | 30,000 | Time allowed for the initial readiness handshake |
| `restart_backoff_min` | 250 | Initial retry delay ceiling |
| `restart_backoff_max` | 30,000 | Maximum retry delay ceiling |
| `restart_backoff_reset_after` | 30,000 | Continuous healthy period before resetting retry history |

The ceiling doubles per failure and actual delay is randomized between half the ceiling and the
ceiling. A successful startup alone does not reset the history. All options must be positive
integers, and the minimum backoff must not exceed the maximum. These are initial defaults to tune
under realistic SSR load, not a claim that 500 ms is suitable for every workload.

`Frontman.status(name).slots` shows all configured worker owners, including unavailable
ones: `phase` (`:starting`, `:ready`, `:suspect`, `:stopping`, `:backoff`, `:cleanup_failed`), Node PID,
failed probes, retry attempt and next delay. `workers/1` still lists only workers that have passed
the probe. A pool admission drain remains in force when a Node replacement becomes ready.

Worker telemetry events use `[:frontman, :worker, event]` for `:start`, `:ready`,
`:unhealthy`, `:restart`, and `:cleanup_failed`. Metadata identifies pool `name` and worker `index`;
restart includes `reason`/`attempt`, and measurements include `delay`/`ceiling` in milliseconds.

This does not add cgroup containment. A wrapper killed unexpectedly can still orphan descendants,
and direct-child cleanup does not guarantee termination of arbitrary grandchildren. Linux process
containment remains separate work.

## Verify independently

Requires Elixir 1.20+, Erlang, a C compiler for MuonTrap, Node on PATH, and POSIX `ps`/`kill` commands (procps in the Linux image):

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Tests cover proxy transport against a real HTTP upstream and worker lifecycle against real
Node processes, including two named pools, crash replacement, registry recovery and shutdown.

## Package preparation

Run the same checks as CI:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix hex.build
```

`mix hex.build` creates a local tarball only. Inspect its contents before a future release.
Publishing to Hex remains a separate, manual step. There is no release or publish workflow.
See [CHANGELOG.md](CHANGELOG.md) for changes.
