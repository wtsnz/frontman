# Measurements

These results come from the catalogue application that Frontman was extracted from. They describe
one workload and environment, not a performance guarantee for the library.

## Direct Ash RPC navigation

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
