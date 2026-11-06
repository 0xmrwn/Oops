# Loopback transport pilot

This pilot measures the production `OpenAICompatibleBackend` from a Release configuration XCTest bundle. A Python standard library server binds an ephemeral port on `127.0.0.1` and returns canned Chat Completions JSON for synthetic input. It serves persistent HTTP/1.1 over HTTP or HTTPS, records scalar socket ordinals, and discards request bodies.

Two sequential calls per pair go through the compatible backend with an empty API key and the same synthetic draft. A task delegate records metrics and rejects redirects and non-fixture authentication challenges. The default mode creates one ephemeral `URLSession` per pair. The `shared` mode uses the backend's default initializer and one `URLSession.shared` across the entire test process. In shared mode, pair positions identify request order and either position may reuse a connection from an earlier pair. The probe uses built-in correction rules via a volatile defaults domain in its test process.

## Run

The reviewed transport pilot at `20c12aa02836d1834b6e782bf6765972e76f3988` needs a per-task delegate overload and its XCTest probe. This integration keeps both in `swift-overlay.patch`. Apply the patch only in a dedicated local checkout, then commit it so the runner can pin the exact source tree.

```sh
probe_checkout=/private/tmp/oops-transport-overlay
git worktree add --detach "$probe_checkout" HEAD
git -C "$probe_checkout" apply --index fixtures/transport-perf/swift-overlay.patch
git -C "$probe_checkout" commit -m 'test: apply local transport measurement overlay'
cd "$probe_checkout"
```

Prepare the pinned SwiftPM checkout and binary artifact under that checkout's `.build` before collection. The runner verifies the two overlay file digests before building. It returns `SWIFT_OVERLAY_REQUIRED` in the shipping checkout. The runner compiles the XCTest bundle in Release with testability for the existing test targets. A sandbox profile denies networking during the build. The selected XCTest invocation permits outbound connections only to the literal loopback fixture port. The runner owns the loopback listener and the child process groups it starts.

```sh
python3 fixtures/transport-perf/run.py collect --out /private/tmp/oops-transport-plan --dry-run
python3 fixtures/transport-perf/run.py collect --out /private/tmp/oops-transport-pilot --pairs 20
python3 fixtures/transport-perf/run.py collect --out /private/tmp/oops-transport-tls --pairs 20 --scheme https
python3 fixtures/transport-perf/run.py collect --out /private/tmp/oops-transport-shared --pairs 20 --session shared
python3 fixtures/transport-perf/run.py collect --out /private/tmp/oops-transport-close --scheme https --session shared --close-after-first
python3 fixtures/transport-perf/run.py schema
```

Use a new output directory outside the checkout. Keep the checkout and its build directory idle during collection. The runner checks the executable digest before and after the probe. The runner uses 20 pairs by default and accepts 1 through 100. `--timeout` sets the limit for each build or probe command in seconds, with a default of 300. The injected ephemeral session has a five-second resource timeout. Shared mode keeps the session defaults and the backend deadline. The probe waits up to two seconds for each task's metrics. Default `just check` skips the socket probe unless the runner sets `OOPS_TRANSPORT_PERF_CONFIG`.

HTTPS mode generates a new synthetic CA and loopback leaf with the local `openssl` tool. The server loads its certificate and key before the runner removes their temporary directory. The public CA remains in the run directory as `probe-anchor.der`. The task delegate evaluates server trust against only that CA for `127.0.0.1` and the fixture port, with trust network fetching disabled. The probe runs inside the port-limited sandbox, and the fixture rejects authorization and cookie headers.

`--close-after-first` makes the fixture send `Connection: close` on the first response of each pair. This control fails if any second request reports connection reuse. First requests in shared mode can still reuse the second request's socket from the preceding pair.

Progress and diagnostics go to stderr. The JSON result on stdout reports the output directory and pair counts. Exit `0` means successful collection, `1` means local failure, `2` means invalid arguments, `3` means a required tool or cache is unavailable, `4` means incomplete or inconsistent evidence, `11` means timeout, and `130` means interruption. A failed run retains its available logs and samples.

## Evidence

| File | Contents |
| --- | --- |
| `manifest.json` | Clean overlay commit and tree, patch, backend, probe and executable hashes, commands, toolchain, host architecture and OS, and session configuration |
| `samples.jsonl` | Backend elapsed time, task duration, outcomes, reuse and protocol, and separate transaction phases |
| `server.json` | Accepted requests by pair and position with socket ordinals, negotiated TLS versions, and TLS session resumption for HTTPS |
| `summary.json` | Planned and complete pair counts, reuse agreement, and distributions for complete pairs |
| `build.log` and `probe.log` | Local command diagnostics |

Durations are milliseconds. Each phase uses its corresponding start and end dates from `URLSessionTaskMetrics`. Missing timestamps omit the phase. The summary keeps missing counts separately from measurements. Invalid values or ambiguous duplicate rows fail collection. The p50 is the median and the p95 uses nearest rank. The second request's `gapMs` measures the time between the first backend return and the next backend call.

`connectMs` can include `tlsMs`, so the summary keeps the phases separate. `waitMs` spans request end to response start and includes more than server execution. Literal IPv4 yields no internet DNS evidence. Reused HTTPS connections may omit handshake phases. The socket ordinals independently check reuse flags across all requests. For HTTPS the summary requires server-side TLS evidence and checks the protocol code when Foundation reports it. It counts distinct sockets whose handshakes resumed a prior TLS session. A disagreement leaves the evidence available with a failing exit status.

These measurements validate local instrumentation and connection observations in an XCTest process. Live providers, internet DNS and TLS, OS cold start, and installed app Release behavior require their own evidence.
