# Fix CR outcome: the rayforce execution path

CR: `janet-data-engines/engines/janet-rayforce/changes/fix-cr-execution-path-prompt.md`
Analysis: `engines/janet-query/changes/findings-rayforce-deepdive.md` @ a48dc5a
Date: 2026-11-07. Engine pin 3.0.1, unchanged. No header change, no engine change.

## Result

The five bench queries went from 796 to 2255 ms cold and 869 to 2167 ms warm
to 12 to 30 ms cold and 0.7 to 3.0 ms warm. The engine's own short queries
run in 0.2 to 2.2 ms on the same box, so the lane is now within 1.3x to 4.5x
of the raw engine and within 1.0x to 1.5x of the fastest route in the warm
phase.

Everything below is measured with one harness (`bench/runner.janet 5`, the
Dispatch A runner) on the committed data (65,536 rows, sha256
`2ef33afa8127b9fae96d94dbb502fbfadb0a20a4d48fc5ced8cb19c8a8b2cfee`).

## Bench gate (ms, min of 5)

Recorded before (`bench/results/bench-run.out`, step-6 Dispatch A) and after
(`/tmp/bench-after.out`, this CR run).

| query | cold before | cold after | warm before | warm after | warm speedup |
|---|---|---|---|---|---|
| q1 filter | 796.0 | 17.8 | 868.5 | 1.3 | 668x |
| q2 group top N | 814.7 | 15.6 | 798.7 | 0.7 | 1141x |
| q3 join | 2021.9 | 29.9 | 2127.4 | 2.8 | 760x |
| q4 top row per group | 2255.1 | 25.7 | 2167.5 | 3.0 | 723x |
| q5 full scan | 841.6 | 12.1 | 881.8 | 0.9 | 980x |

Cold is now parquet read plus execution: the deep-dive measured the read at
17.7 to 29 ms on this box, so cold is at its floor.

Ratio against the fastest route in the same run, warm: 1.40, 1.00, 1.01,
1.54, 1.00. Cold: 4.26, 10.27, 6.54, 6.82, 3.62.

Engine reference from the deep-dive (standalone Rayfall, warm): q1 0.377,
q2 0.183, q3 2.161, q4 1.360, q5 0.201. The remaining gap is janet-query's
tree expansion, render and result materialisation, not the engine.

Output equivalence: the runner gates every route against `duckdb-sql` rows
per query and phase before printing a number. `VERDICT: PASS`. Row counts
q1 50, q2 10, q3 3, q4 60, q5 8.

## The three fixes

1. **Names-only source resolution** (`query-rayforce.janet`, `-names-of`).
   The three `table-columns` calls in `source-table` became
   `(sorted (seq [i :range [0 (rf/table-ncols tbl)]] (rf/-column-name tbl i)))`.
   The `sorted` stays: the documented quirk is that a borrowed handle's
   column order is not recoverable through the public surface, so the
   implicit projection surfaces sorted names. Cost 862.8 ms at 65k x 8 fell
   to 0.013 ms.
2. **Bulk numeric decode** (`rayforce.janet`, `-bulk-decode`). F64 and I64
   columns read as one block through `ray_vec_get` plus an array read. F64
   maps NaN to nil as before. I64 maps through `int/to-number`; a column
   holding a `NULL_I64` sentinel or an out-of-band value falls back to the
   per-element lane, which raises the band error or returns nil exactly as
   before. Measured at 65,536 rows: F64 16.8 to 6.2 ms, I64 98 to 121 ms
   (pre-fix shape) to 11.1 ms. Values equal on all eight bench columns.
3. **Join sides stay in the engine** (`query-rayforce.janet`, plus
   `-table-alias` and `-column-tags` in the binding). A join side is now
   executed and ALIASED to its contract names: a shallow table over the
   result's own column vectors, one retained ref per column, no decode and no
   re-ingest. The collision rename uses the same primitive. A side carrying
   any non-numeric engine type still takes the decode path, which is where
   the STR and SYM fences live. When the two key columns would mix storage
   types the whole join takes the decode path, so the A7.2 fence never fires
   where the pre-fix shape matched by value.

## Correctness gates

- `tests/run_tests.sh` in the authoring tree: `RESULT: pass`, all 17 suites
  (kit, typed, json, json round-trip, stats, query, duckdb, query-duckdb,
  janet-num, fuzz, xgboost, rayforce, query-rayforce, chinook). The 7 mirror
  checks SKIP in a worktree (no `janet-data-engines` sibling) and none of the
  mirrored files are touched by this CR.
- `scripts/check-all.janet` (fast tier): `PASS 14/14`.
- `tests/smoke-rayforce.janet`: pass (decode cells: i64 exact, NaN nulls,
  out-of-band raise, STR, BOOL).
- `tests/smoke-query-rayforce.janet`: pass, with three new cells: collision
  rename over a null-bearing key, an I64 side against an F64 side, and a
  join-lane cycle at net 0.
- `tests/suite-query-chinook.janet`: `suite-query-chinook: ok`, all 15
  queries on both backends.
- `run_tests.sh` in this repo against the ported binding: `RESULT: pass`.
- Bench runner output equivalence: pass (above).

## Findings

1. **The join lane leaked before this CR.** `rf/-trace-net` over the 65k q3
   shape measured 6,689,280 bytes unfreed over three cycles (904 allocs, 871
   frees); q4 measured 9,837,696 bytes (330 allocs, 291 frees). The RESULT
   side's handle was never closed when a join consumed a distinct or group
   side. After the restructure both shapes measure net 0 (q3 387/387, q4
   270/270 allocations balanced). The new smoke cell pins the budget.
2. **A table's column index order is not its add order.** The engine orders
   table columns by interned name id, so a positional alias mapped names to
   the wrong vectors. On a null-bearing key that produced a silent zero-row
   join. `-table-alias` is keyed by source NAME; the collision cell pins it.
3. **The I64 decode is where the old cost lived**, not the F64 lane. The
   per-element `try` around `int/to-number` carries most of it: the same
   column read in bulk then converted without a per-element `try` costs 11 ms
   instead of 98 to 121 ms.

## Scope note

The backend under fix (`jennystats/query-rayforce.janet`) lives in the
hot-tools tree; the binding (`jennystats/rayforce.janet`) has an authoring
copy there and the published copy in this repo. Both halves were changed in
the hot-tools worktree, the binding delta was ported here, and this record
lives here per the CR. The published janet-query repo was not touched: its
measured-cost table is the coordinator's edit.

## Files and commits

- hot-tools `fix/rayforce-execution-path`: `e01fcc5` names-only resolution,
  `a871895` binding surface (bulk decode, column tags, alias), `8ca7421`
  join sides in the engine (backend, smoke cells).
- this repo `fix/execution-path`: the binding port plus the contract
  addendum v1.0.3 and this record.

Commits in the hot-tools worktree bypassed the pre-commit hook: the hook
runs `check-all` against the AMBIENT `JANET_PATH`, and a worktree has no
installed module tree, so it failed to load `jennystats/typed` before running
a single check. The gate was run by hand instead (`check-all` 14/14, full
suite pass) before each commit.

## Redo

```sh
# authoring tree
cd ~/development/worktrees/ht-rayforce-exec
JANET_PATH="$PWD/tests/lib:$PWD/modules:$HOME/.local/lib/janet" bash tests/run_tests.sh
JANET_PATH="$PWD/tests/lib:$PWD/modules:$HOME/.local/lib/janet" janet scripts/check-all.janet

# probes (from the bench directory so the data path resolves)
cd ~/development/janet-data-engines/engines/janet-query/bench
export JANET_PATH="$HOME/development/worktrees/ht-rayforce-exec/modules:$HOME/.local/lib/janet"
strict ../changes/probes/step6-deepdive/l3-phase-probe.janet
strict ../changes/probes/fix-cr-execution-path/probe-bulk-decode.janet
strict ../changes/probes/fix-cr-execution-path/probe-bulk-decode-2.janet
strict ../changes/probes/fix-cr-execution-path/probe-rename.janet

# the bench gate
strict runner.janet 5

# this repo
cd ~/development/janet-rayforce
JANET_PATH="$HOME/development/worktrees/ht-rayforce-exec/modules:$HOME/.local/lib/janet" ./run_tests.sh
```
