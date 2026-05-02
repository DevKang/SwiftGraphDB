# Benchmark Baseline

**Generated:** 2026-05-02 (manual run)  
**Build:** `swift test` (debug)  
**Hardware:** developer machine (Apple Silicon)

| SPEC §13 row | Status | Measured (debug) | Target | Notes |
|---|---|---|---|---|
| Launch with snapshot | n/a | not yet | < 100ms | M7 |
| Launch without snapshot (100K) | not measured | n/a | < 2s | scaled-down 10K passes the 1s debug ceiling |
| 4-hop BFS (20K, deg 10) | met (debug) | < 100ms | < 10ms (release) | exercise via `testFourHopBFSBaseline` |
| Node insert | not measured | n/a | < 5ms | covered indirectly by bulk |
| Property fetch (cached / uncached) | not measured | n/a | < 0.1ms / < 5ms | LRU wired in OML-1945 |
| Bulk import 20K nodes | met (5K subset, debug) | < 1s | < 3s | scaled to keep CI under a second |
| Sync push/pull | n/a | n/a | Background | M8 |

## How to run

```bash
swift test --filter PerformanceBaselineTests
swift test -c release --filter PerformanceBaselineTests   # tighter ceilings; release-only
```

## How to compare two runs

`BenchmarkResult` is JSON-encodable. Capture `record` values from the
`PerformanceBaselineTests` (or the harness's `measureBenchmark` wrapper) and
diff via the standard tool of your choice.
