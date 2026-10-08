# Changelog

## Unreleased

Initial extraction from a Phoenix, Ash and TanStack Start application. Experimental; not published to Hex.

- Independently named supervised pools with readiness handshakes.
- Streaming Plug proxy with backend route passthrough and trace propagation.
- Bounded admission, monitored request reservations, drain and resume.
- Health probes, restart backoff, and direct-child process cleanup.
- Runtime telemetry and real Node integration tests.
- Guides in `docs/`: purpose, setup with Phoenix, Ash and TanStack Start, internals, operations and reference.
- Setup examples for shared SSR/browser loaders, the trusted public origin and the tested Nitro build.
- Context and results for the catalogue's deployed navigation CPU measurement.
- `port` pool option: proxy to a server Frontman doesn't run, such as the Vite dev server.
- The proxy sets `X-Forwarded-Host` from the `Host` header, keeping a non-default port.
- `mix frontman.package`: builds the frontend with a pinned Node, verified against Node's published
  SHA-256 and cached between runs, and copies the `node` binary and the build into `priv` for the
  release. Configured through `config :frontman, :package`.
