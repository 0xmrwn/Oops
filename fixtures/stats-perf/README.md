# Synchronous statistics loading probe

This fixture compares an existing git revision with the checkout's `Stats.swift`, compiled separately with `-O`, Swift 6 and the arm64 macOS 26 deployment target. It appends a same-file accessor to the production loader; it never constructs `Stats` or accesses `Stats.shared`. A fixed `DebugFlags` substitute prevents defaults access. The sandbox denies networking and reads or writes under the real `Application Support/oops` directory during compilation and execution.

Run only in a coordinated quiet window:

```sh
python3 fixtures/stats-perf/run.py --baseline efaebb0 --out /private/tmp/oops-stats-comparison-01
```

The output directory must be new and outside the checkout. It retains source copies, commands, hashes, compile/run logs and `summary.json`. Each executable loads the same 10,000 distinct synthetic events six times, then a second history containing one malformed line. `--events 1000` selects the smaller control and `--repetitions` accepts 1–20. The runner verifies decoded event counts and fingerprints including every field before accepting the result. Inputs contain all five outcomes, distinct dates and Unicode; they contain no user history.

Durations are milliseconds measured around synchronous main-actor `Stats.load`, excluding fingerprint calculation. These are repeated warm-filesystem observations within each standalone process, in fixed baseline-then-candidate order. They characterize the loading algorithm, not first frame, native Settings responsiveness, disk-cold startup, memory consumption or release acceptance. The full load remains synchronous. Correctness tests additionally retain legacy CRLF, BOM, malformed-line and invalid-UTF8 behavior.
