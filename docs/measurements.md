# Measurements

These results describe one workload and environment each, not a performance guarantee for the
library.

## Direct Ash RPC navigation

From the catalogue application that Frontman was extracted from.

Recorded on 2026-09-26 on `test1.tinbird.shop`, with 2 CPUs and 1.9 GiB of memory. The workload was
one page load followed by 80 client-side navigations.

The application changed its route loaders from Start server functions to isomorphic loaders that
call Ash RPC directly from the browser. Phoenix also began serving the build's hashed assets.
The recorded comparison includes both changes; it does not isolate their individual effects.

| Measurement | Before | After |
| --- | --- | --- |
| Navigation requests | 80 `/_serverFn` requests through Node | 80 `/rpc/run` requests to Phoenix |
| Node CPU time | 0.53 s | 0.11–0.12 s |
| BEAM CPU time | 0.53 s | 0.32–0.33 s |
| Time per two-navigation round from the test client | 67 ms | 67–68 ms |

Combined Node and BEAM CPU fell by about 58%. Client-observed navigation time was unchanged.
The original findings attributed the wall time to client round-trip latency, but this comparison
does not isolate that cause. The original results are recorded in the catalogue's
`docs/findings.md`, under "Node for SSR only (2026-09-26)".

These are retained findings, not a reproducible benchmark suite. They do not establish throughput,
tail latency, behavior under load, or a production worker count.

## Page cache

Recorded on 2026-10-08 on an Apple M4 Max (16 cores, 128 GB) with macOS 26.6, Erlang/OTP 28,
Elixir 1.20.0, Node 22.22.3 and oha 1.16.0, all on the same machine.

The app was [frontman_starter](https://github.com/wtsnz/frontman_starter) at `5d7247c`, using
Frontman from the branch that added the cache, with a public `/about` route added: a 4,414-byte page whose root loader asks Phoenix for the session
over loopback, as it does for every page in the starter. It ran with `MIX_ENV=prod`, two Node
workers, the BEAM limited to two schedulers (`+S 2:2`), and the log level at `warning` so request
logging didn't dominate. The cache used `query: {:except, ["utm_source", "utm_medium",
"utm_campaign"]}` and the route sent `x-frontman-cache: public, max-age=60,
stale-while-revalidate=600`. For the uncached runs the same build ran without the `cache` option.

Each run was `oha -z 30s -c 32` against `http://127.0.0.1:4100/about`, after a five-second warm-up.
CPU per request is the change in cumulative CPU time of the BEAM and its Node processes, from
`ps`, divided by the requests served. Every response was a 200.

| Run | Requests/s | p50 | p99 | CPU per request (BEAM + Node) |
| --- | --- | --- | --- | --- |
| Uncached | 3,879 | 7.96 ms | 23.92 ms | 0.421 + 0.731 = 1.152 ms |
| Uncached, `Accept-Encoding: gzip` | 3,659 | 8.29 ms | 26.18 ms | 0.440 + 0.760 = 1.200 ms |
| Cached | 25,708 | 1.23 ms | 1.72 ms | 0.071 + 0 = 0.071 ms |
| Cached, `Accept-Encoding: gzip` | 26,285 | 1.20 ms | 1.90 ms | 0.069 + 0 = 0.069 ms |

A cached page cost about 6% of the CPU of a rendered one, and Node did no work. Bandit gzips
cached pages on each response; for this page that cost too little to show. The cached runs are
probably limited by oha sharing the machine, so treat their throughput as a floor.

The app that motivated the cache measured about 8 ms of CPU per uncached page on 2-vCPU servers,
two thirds of it in Node. This laptop renders the starter's page much faster, so compare the
ratio, not the milliseconds.
