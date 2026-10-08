# Setup

This guide adds Frontman to a Phoenix app that uses Ash and AshTypescript, with a TanStack
Start app in `frontend/`. The snippets use `MyApp` and `MyAppWeb`. Rename to match your app.

By the end, Phoenix will:

- serve the Start build's hashed assets itself,
- send `/rpc/*`, `/auth/*` and other backend paths to the router,
- stream every other request from a supervised Node worker,
- report pool readiness in its health check.

## 1. Add the dependency

```elixir
# mix.exs
{:frontman, github: "wtsnz/frontman", branch: "main"}
```

```sh
mix deps.get
```

MuonTrap compiles a small C program, so the build machine needs a C compiler. The runtime host
needs `ps` and `kill`. On Debian and Ubuntu images that's the `procps` package.

## 2. Configure where Node and the build live

Frontman runs an executable with arguments in a directory. This guide uses a Nitro `node-server`
build, which produces `.output/server/index.mjs` and `.output/public` in the frontend directory.

The catalogue integration was tested with `@tanstack/react-start` 1.168.58,
`@tanstack/react-router` 1.170.39, Nitro 3.0.260903-beta, Vite 8.3.1 and Node 22. These are the
tested frontend versions, not Frontman dependencies or a compatibility guarantee for other
versions. Configure your existing Start app's Vite plugins:

```typescript
// frontend/vite.config.ts
import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { nitro } from "nitro/vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [tanstackStart(), nitro({ preset: "node-server" }), react()],
});
```

Include `nitro` in your frontend dependencies and use `vite build` for its build script.
This is the Node adapter setup required by the paths below. See TanStack's
[hosting guide](https://tanstack.com/start/latest/docs/framework/react/guide/hosting) for adapter
configuration when upgrading the frontend.

```elixir
# config/config.exs
config :my_app, :frontend,
  enabled: false,
  workers: 1,
  max_concurrency: 16,
  node: "node",
  public_origin: "http://localhost:4000",
  directory: Path.expand("../frontend", __DIR__)
```

```elixir
# config/runtime.exs
if config_env() == :prod do
  priv = :code.priv_dir(:my_app) |> to_string()

  config :my_app, :frontend,
    # Only start Node when the release serves HTTP, not for one-off tasks like migrations.
    enabled: System.get_env("PHX_SERVER") != nil,
    workers: String.to_integer(System.get_env("FRONTEND_WORKERS", "#{System.schedulers_online()}")),
    max_concurrency: String.to_integer(System.get_env("FRONTEND_MAX_CONCURRENCY", "16")),
    node: System.get_env("NODE_BINARY", Path.join(priv, "node/bin/node")),
    public_origin: System.fetch_env!("PUBLIC_ORIGIN"),
    directory: System.get_env("FRONTEND_DIR", Path.join(priv, "frontend"))
end
```

Use an absolute path for `node` in production. MuonTrap runs it directly, without a shell.

`PUBLIC_ORIGIN` is the visitor-facing origin, for example `https://shop.example.com`. The server
entry uses it for redirects and absolute URLs. `BACKEND_URL` is Phoenix's internal listener address,
for example `http://127.0.0.1:4000`; the pool wrapper below supplies it for SSR RPC calls.
Configure both in the host application. Frontman doesn't infer or validate the public origin.

Add a small module to read this config:

```elixir
defmodule MyApp.Frontend do
  @moduledoc "Configuration for the TanStack Start pool."

  def config, do: Application.fetch_env!(:my_app, :frontend)
  def enabled?, do: config()[:enabled] == true
  def public_dir, do: Path.join(config()[:directory], ".output/public")
  def workers, do: Frontman.workers(MyApp.SSR)
end
```

## 3. Start the pool after the endpoint

SSR loaders call Phoenix, so the pool should start after the endpoint is listening, and the
workers need its address. Read it at start time, so a port picked at runtime still works:

```elixir
defmodule MyApp.FrontendPool do
  @moduledoc "Starts the Node SSR pool once Phoenix is listening."

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  def start_link(_opts) do
    config = MyApp.Frontend.config()

    Frontman.start_link(
      name: MyApp.SSR,
      executable: config[:node],
      args: [".output/server/index.mjs"],
      directory: config[:directory],
      workers: config[:workers],
      max_concurrency: config[:max_concurrency],
      env: [
        {"BACKEND_URL", backend_url()},
        {"PUBLIC_ORIGIN", config[:public_origin]}
      ]
    )
  end

  defp backend_url do
    {:ok, {address, port}} = MyAppWeb.Endpoint.server_info(:http)

    host =
      case address do
        {0, 0, 0, 0} -> "127.0.0.1"
        {0, 0, 0, 0, 0, 0, 0, 0} -> "127.0.0.1"
        address when tuple_size(address) == 8 -> "[#{:inet.ntoa(address)}]"
        address -> address |> :inet.ntoa() |> to_string()
      end

    "http://#{host}:#{port}"
  end
end
```

```elixir
# lib/my_app/application.ex
children =
  [
    MyAppWeb.Telemetry,
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    MyAppWeb.Endpoint
  ] ++ if(MyApp.Frontend.enabled?(), do: [MyApp.FrontendPool], else: [])
```

Frontman sets `HOST`, `PORT`, `FRONTEND_WORKER_TOKEN` and `SERVER_SHUTDOWN_TIMEOUT` for each
worker. Don't put those in `env`. Everything else in the BEAM's environment passes through to
Node.

## 4. Add the plugs to the endpoint

Order matters. Assets first, so Node never serves a file Phoenix can. Then the proxy, before
`Plug.Parsers`, so it forwards request bodies untouched.

```elixir
# lib/my_app_web/endpoint.ex
socket "/socket", MyAppWeb.UserSocket, websocket: true, longpoll: false

plug Plug.RequestId
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

plug MyAppWeb.FrontendAssets
plug MyAppWeb.FrontendProxy

plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library()

plug Plug.MethodOverride
plug Plug.Head
plug Plug.Session, @session_options
plug MyAppWeb.Router
```

Put sockets above the proxy. Frontman doesn't proxy WebSocket upgrades.

### The proxy wrapper

Phoenix runs a plug's `init/1` at compile time, so options passed in `plug Frontman.Proxy, ...`
are fixed in the build. Wrap the proxy to read the enabled flag at runtime:

```elixir
defmodule MyAppWeb.FrontendProxy do
  @moduledoc "Sends page requests to the SSR pool and leaves backend paths to the router."
  @behaviour Plug

  @pass_through ["/rpc/", "/auth/", "/webhooks/", "/health/", "/socket/"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Frontman.Proxy.call(conn,
      name: MyApp.SSR,
      enabled: MyApp.Frontend.enabled?(),
      pass_through: @pass_through
    )
  end
end
```

Every route in your Phoenix router needs a prefix in `pass_through`. A route without one is
unreachable, because the proxy answers the request first.

### Static assets

TanStack Start writes client files to `.output/public`. Files under `assets/` have a content
hash in their name, so they can be cached forever:

```elixir
defmodule MyAppWeb.FrontendAssets do
  @moduledoc "Serves the Start build's public files without a Node worker."
  @behaviour Plug

  @hashed Plug.Static.init(
            at: "/",
            from: {MyApp.Frontend, :public_dir, []},
            only: ~w(assets),
            cache_control_for_etags: "public, max-age=31536000, immutable"
          )

  @public Plug.Static.init(
            at: "/",
            from: {MyApp.Frontend, :public_dir, []},
            only: ~w(fonts images favicon.svg robots.txt)
          )

  @impl true
  def init(_opts), do: nil

  @impl true
  def call(conn, _opts) do
    if MyApp.Frontend.enabled?(),
      do: conn |> Plug.Static.call(@hashed) |> serve_public(),
      else: conn
  end

  defp serve_public(%Plug.Conn{halted: true} = conn), do: conn

  # A stale hashed asset is a 404, not a page request.
  defp serve_public(%Plug.Conn{path_info: ["assets" | _]} = conn),
    do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  defp serve_public(conn), do: Plug.Static.call(conn, @public)
end
```

Adjust the `only:` list in `@public` to match what's in your `public/` folder.

## 5. Update the Start server entry

The server entry answers Frontman's readiness probe and rebuilds the request URL using the
configured `PUBLIC_ORIGIN`. Workers listen on `127.0.0.1:<random port>`, which must not become the
public origin for redirects or absolute URLs. Frontman preserves incoming forwarded headers;
they are not proof of the public origin. This example uses application configuration instead.

```typescript
// frontend/src/server.ts
import handler, { createServerEntry } from "@tanstack/react-start/server-entry";

export default createServerEntry({
  async fetch(request) {
    const url = new URL(request.url);

    // Frontman probes each worker with the token it generated for this start. The pid is
    // Node's own, not MuonTrap's wrapper. The proxy returns 404 for /__frontend/* from browsers.
    if (url.pathname === "/__frontend/ready") {
      const token = process.env.FRONTEND_WORKER_TOKEN;
      return token
        ? Response.json({ token, pid: process.pid }, { headers: { "Cache-Control": "no-store" } })
        : new Response("Not found", { status: 404 });
    }

    const origin = process.env.PUBLIC_ORIGIN;
    if (origin) {
      const publicUrl = new URL(origin);
      publicUrl.pathname = url.pathname;
      publicUrl.search = url.search;
      request = new Request(publicUrl, request);
    }

    return handler.fetch(request);
  },
});
```

Answer the probe from the Node event loop. If the event loop is blocked, the probe should fail.
That's how Frontman spots a hung worker.

## 6. Load data through Ash RPC

Use one route loader and one generated Ash RPC call in both environments. The transport is the
part that changes:

| When the loader runs | Where it runs | How it calls Ash |
| --- | --- | --- |
| Initial server render | Node | Fetches `BACKEND_URL` over loopback, forwarding the visitor's cookies |
| Client-side navigation or preloading | Browser | Fetches same-origin `/rpc/run` directly, with the browser's cookies |

The server returns the initial loader data with the rendered page for hydration. Client-side
navigation runs the loader in the browser; it doesn't need a Start server function to invoke it.
TanStack Router's caching and preload settings control whether a navigation fetches new data.

Give the generated AshTypescript functions a `customFetch` built with `createIsomorphicFn`:

```typescript
// frontend/src/lib/rpc.ts
import { createIsomorphicFn } from "@tanstack/react-start";
import { getRequestHeaders } from "@tanstack/react-start/server";

export const rpcFetch = createIsomorphicFn()
  .server((input: RequestInfo | URL, init?: RequestInit) => {
    // SSR calls Phoenix on its internal address, as the visitor.
    const incoming = getRequestHeaders();
    const headers = new Headers(init?.headers);
    for (const name of ["cookie", "x-request-id"]) {
      const value = incoming.get(name);
      if (value) headers.set(name, value);
    }
    const origin = process.env.PUBLIC_ORIGIN;
    if (origin) {
      const publicUrl = new URL(origin);
      headers.set("x-forwarded-host", publicUrl.host);
      headers.set("x-forwarded-proto", publicUrl.protocol.slice(0, -1));
    }
    return fetch(new URL(String(input), process.env.BACKEND_URL || "http://127.0.0.1:4000"), {
      ...init,
      headers,
      signal: AbortSignal.timeout(8000),
      redirect: "manual",
    });
  })
  .client((input: RequestInfo | URL, init?: RequestInit) =>
    // The browser calls same-origin /rpc/run. Node never sees it.
    fetch(input, { ...init, signal: AbortSignal.timeout(8000) }),
  );
```

```typescript
// frontend/src/lib/products.ts
import { listProducts } from "@/ash_rpc";
import { rpcFetch } from "./rpc";

export async function loadProducts() {
  const result = await listProducts({
    fields: ["id", "name", "price"],
    customFetch: rpcFetch,
  });
  if (!result.success) throw new Error(result.errors.map((e) => e.message).join("; "));
  return result.data;
}
```

Call the shared data function from a route loader. The component reads the result through
`Route.useLoaderData()` in both the server render and the browser:

```tsx
// frontend/src/routes/index.tsx
import { createFileRoute } from "@tanstack/react-router";
import { loadProducts } from "../lib/products";

export const Route = createFileRoute("/")({
  loader: () => loadProducts(),
  component: Products,
});

function Products() {
  const products = Route.useLoaderData();
  return (
    <ul>
      {products.map((product) => (
        <li key={product.id}>{product.name}</li>
      ))}
    </ul>
  );
}
```

Keep this data function out of `createServerFn`. When called from the browser, a Start server
function sends a request back to Node. `createIsomorphicFn` selects a local implementation for
each environment, so the browser's loader calls Phoenix directly. Use the same `rpcFetch` for
generated Ash mutation functions called by your forms; Frontman doesn't change their transport
automatically. This pattern keeps navigation data and Ash RPC writes off Node, while full page
renders and any Start server functions or server routes still need it.

The server side forwards the visitor's cookies to Phoenix, so Ash sees the same actor during
SSR as in the browser. It does not copy `Set-Cookie` from the RPC response onto the page. If
your session can renew during a page load, handle that in Phoenix (for example in a plug on
`/auth`) rather than relying on SSR.

## 7. Report readiness

Frontman doesn't mount a health endpoint. Add the pool to yours:

```elixir
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  def ready(conn, _params) do
    workers = Enum.count(MyApp.Frontend.workers(), &(&1.state == :ready))
    database? = match?({:ok, _}, Ecto.Adapters.SQL.query(MyApp.Repo, "SELECT 1"))
    frontend? = not MyApp.Frontend.enabled?() or workers > 0

    conn
    |> put_status(if database? and frontend?, do: 200, else: 503)
    |> json(%{database: database?, frontend: %{ready: workers}})
  end
end
```

Count only workers in `:ready` state. During a drain, `workers/1` still lists them with
`state: :draining`, and a load balancer should stop sending traffic. A full pool returns 503 per
request but doesn't need to fail readiness.

## 8. Development

Frontman's workers run production builds. The simplest development setup leaves
`enabled: false` and runs Vite yourself. Point Vite's own proxy at Phoenix for backend paths:

```typescript
// frontend/vite.config.ts
export default defineConfig({
  server: {
    port: 5173,
    proxy: {
      "/rpc": "http://127.0.0.1:4000",
      "/auth": "http://127.0.0.1:4000",
      "/socket": { target: "ws://127.0.0.1:4000", ws: true },
    },
  },
  // ...plugins
});
```

Open `http://localhost:5173`. SSR loaders reach Phoenix through the `BACKEND_URL` default.
Set `PUBLIC_ORIGIN=http://localhost:5173` for Vite so the server entry uses the development origin.

To run the real pool locally, build the frontend and enable it:

```sh
npm --prefix frontend run build
```

```elixir
# config/dev.exs
config :my_app, :frontend, enabled: true, workers: 2
```

### Phoenix in front of Vite

To keep cookies, hosts and backend routes the same as in production, open Phoenix instead and
let it proxy page requests to Vite. Start a pool with `port` instead of `executable`, `args` and
`directory`. Frontman then sends requests to that port and doesn't start, probe or restart
anything there:

```elixir
# lib/my_app/application.ex, when MyApp.Frontend.dev?()
{Frontman, name: MyApp.SSR, port: 5173, max_concurrency: 256}
```

Run Vite yourself, or as an endpoint watcher. The proxy wrapper and readiness check stay the
same. A development page loads hundreds of unbundled modules through the proxy, so raise
`max_concurrency`. Frontman doesn't proxy WebSocket upgrades, so point Vite's HMR client at Vite
directly with `server.hmr.clientPort`. While Vite isn't listening, page requests get `503`.

## 9. Ship it in a release

The release needs the Start build and a Node binary for the platform it runs on.
`mix frontman.package` builds the frontend and puts both in `priv`:

1. It downloads the official Node archive for the build machine's OS and CPU, and checks it
   against Node's published `SHASUMS256.txt`.
2. It runs `npm ci` and `npm run build` in `frontend/` with that Node, so the build machine
   doesn't need Node installed.
3. It copies the `node` binary to `priv/node/bin/node` and `frontend/.output` to
   `priv/frontend/.output`, the paths the production config in step 2 reads.

Pin the Node version and run the task before `mix release`:

```elixir
# config/config.exs
config :frontman, :package, node_version: "22.22.2"
```

```elixir
# mix.exs
defp aliases do
  [
    "assets.deploy": ["frontman.package"]
  ]
end
```

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

If you already have an `assets.deploy` alias, for example for Phoenix's esbuild and tailwind,
add `"frontman.package"` to its list.

Run it on the platform the release targets, such as the Linux container that builds your release.
Node is downloaded for the machine the task runs on, and `npm ci` installs native packages for
it. Only the `node` binary and Node's license ship; npm stays behind. Verified downloads are cached
in `~/.cache/frontman` (`~/Library/Caches/frontman` on macOS), or `$FRONTMAN_CACHE_DIR`.

The task fails on a checksum mismatch, an unsupported platform (it supports Linux and macOS,
x64 and arm64, with glibc), a failed npm command, or a build that writes no `.output`. It only
touches `priv` after the build succeeds. Ignore its output in Git:

```gitignore
/priv/node/
/priv/frontend/
```

The frontend directory, build command, output and destinations are configurable. See
[Reference](reference.md#mix-frontmanpackage).

### In a build container

The frontend is now release source. If your build tool hashes source files to decide whether a
build is current, or to key a build cache, include the frontend directory, without
`node_modules` and the build's output. Otherwise a change only to the frontend leaves an old build
looking current.

Keep the frontend's `node_modules` out of the build context. In `.dockerignore`, `node_modules`
matches only at the root; use `**/node_modules`. `npm ci` deletes a copied one before
installing, so it only slows the build.

A builder that starts empty each time downloads Node and runs `npm ci` from scratch on every
build, which is slower and needs nodejs.org and the npm registry to be reachable. To reuse
downloads, keep `$FRONTMAN_CACHE_DIR` and npm's cache on storage that outlives the build, for
example with BuildKit cache mounts, which only help if the builder itself is kept between builds:

```dockerfile
RUN --mount=type=cache,target=/root/.cache/frontman \
    --mount=type=cache,target=/root/.npm \
    mix assets.deploy
```

`node_mirror` can point at an internal mirror of `nodejs.org/dist` instead.

With `PHX_SERVER=true`, the pool starts after the endpoint. The runtime image needs `ps` and
`kill`, and the shared libraries Node links: glibc, `libstdc++` and `libgcc_s`, which Debian and
Ubuntu images include. To use a Node installed on the host instead, skip the task and set
`NODE_BINARY`. Frontman gives each worker `SERVER_SHUTDOWN_TIMEOUT=4` (seconds), which Nitro uses
to drain connections on SIGTERM.

Read [Operations](operations.md) before your first deploy. It covers draining the pool during a
cutover and the telemetry worth alerting on.
