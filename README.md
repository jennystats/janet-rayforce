# janet-rayforce

The Rayforce columnar engine in the Janet process, via core ffi - no
jpm native module, no Janet-side C build. It exposes the engine's raw
plan plane: build a graph of table ops and expressions, execute it,
read the result table back; parquet files read as flat I64/F64
columns, bitwise-exact. The engine is pinned to
[RayforceDB/rayforce](https://github.com/RayforceDB/rayforce) v2.11.5
by a sha256-verified installer that also cross-checks the four ABI
headers against their content hashes before every build.

Part of [Jenny Stats](https://github.com/jennystats), a home for Janet
data and statistics packages. Jenny is just Janet.

## Quick start

All jenny modules install under a `jennystats/` namespace directory:
`(import jennystats/rayforce)` - collision-proof against bare-name
shadowing of core symbols or other packages, by construction.

```janet
(import jennystats/rayforce :as rayforce)

(def tbl (rayforce/table-from-columns @{:id @[1.0 2.0 3.0 4.0]
                                       :v  @[0.1 3.25 3.5 2.0]}))
(with [g (rayforce/graph tbl)]
  (def res (rayforce/execute g
    (rayforce/select g
      (rayforce/filter g
        (rayforce/const-table g tbl)
        (rayforce/gt g (rayforce/scan g "v")
                        (rayforce/const-f64 g 3.0)))
      [(rayforce/scan g "id")])))
  # @[2.0 3.0]
  (print (rayforce/table-column res "id"))
  (:close res))
```

The `:as` alias is the form used in this repo's tests; the plain
import gives the same call sites with the `rayforce/` prefix.

## What it is

- `(table-from-columns cols)` builds a table from column arrays, a
  name -> array struct, or a [janet-num](https://github.com/jennystats/janet-num)
  packed f32 handle (widened to f64, lossless). Number arrays always
  build F64 columns - the R `c()` model; integer storage arrives from
  parquet and execute results, never from inference.
- `(graph tbl)` -> graph handle; `scan`, `const-table`, arithmetic /
  comparison / logic expression ops, `filter`, `select`, `sort`,
  `group`, `distinct`, `join`, `head`, `tail`, `optimize` build the
  plan; `(execute g root)` runs it and returns a table handle.
- `(parquet-rows path &opt batch)` reads every parquet batch as an
  owned table handle. The reader supports flat I64/F64 columns; every
  other column type raises `unsupported column type: <T> - deferred`,
  and DECIMAL or nested schemas raise at open - loud, never coerced,
  never a shortened table.
- **Null mapping is unified**: Janet `nil` and any NaN value are the
  same encoding in both directions (the R `is.na` semantics; the
  engine's F64 model has no separate null bitmap - an upstream design
  decision, deliberately retained).
- **Ownership**: table and graph handles carry an idempotent `:close`,
  so `with` works; `execute` results are owned tables; ops are
  graph-scoped borrows, not handles. A failed consuming call leaves
  nothing to release - the caller drops the cell.
- **Guards, and what they are not**: the guards catch programming
  errors at the API surface - wrong-kind handles, use-after-close,
  cross-graph confusion, malformed plans; every such path raises. They
  are not a sandbox: code running in the same process can reach the
  module's state and the engine's ffi directly, and the module does
  not attempt to defend against that caller.
- **Embedding statement**: the module embeds the FULL Rayforce engine
  - the Rayfall string evaluator is in the binary and cannot be
  removed by build or link choices - but it is never exposed: no
  public function evaluates a string; the parquet reader never reaches
  it; only caller-constructed plan nodes feed the expression path.

The behavioural specification is `specs/api-contract.md` (v1.0.1):
preconditions, ownership, the error taxonomy, null mapping and the
boundary statement above, stated contractually.

## Install

The module binds the engine's C ABI over ffi, so it needs the pinned
shared library (sha256-verified, idempotent):

```bash
libs/install-rayforce.sh   # rayforce v2.11.5 -> ~/.local/lib/rayforce/
```

Module dependencies: [janet-num](https://github.com/jennystats/janet-num)
(the packed f32 seam - packed handles widen to f64 columns - and the
kernel lib the test suite uses). The `typed` runtime-contract module
is vendored in this package's `jennystats/` directory. With the
library in place:

```bash
jpm install https://github.com/jennystats/janet-rayforce
```

Lib resolution at import: `$RAYFORCE_LIB`, then
`~/.local/lib/rayforce/librayforce.so`, then the system dlopen
search. The import fails with an actionable message if none loads.

Platform: Linux x86_64 built and tested; macOS compile-plausible,
unverified; the Windows route is WSL2. No thread-safety promise:
concurrent calls from multiple Janet threads are undefined behaviour.

## Tests

```bash
./run_tests.sh
```

The smoke suite covers conformance round-trips (f64 bitwise, i64
exact, the unified null/NaN mapping), parquet reads and rejections
(DECIMAL schema, dictionary encoding, deferred types), the ownership
stress loop (every cycle inside the engine's own memory trace; the
pass condition is net bytes 0, alloc == free), guard regressions
(handle provenance, plan-build totality, destructor behaviour) and
the embedding statement. It skips cleanly when librayforce or the
janet-num kernel is absent; present-but-broken is a fail, never a
skip.

## License

AGPLv3 - see `LICENSE`. The bound Rayforce engine is MIT; its notice
ships with the upstream source pinned by the installer.

## AI assistance

The code in this repository was written with the assistance of a
large language model and reviewed by its maintainer.
