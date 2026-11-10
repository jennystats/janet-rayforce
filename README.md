# janet-rayforce

The Rayforce columnar engine in the Janet process, via core ffi - no
jpm native module, no Janet-side C build. It exposes the engine's raw
plan plane: build a graph of table ops and expressions, execute it,
read the result table back; parquet files read as flat I64/F64
columns, bitwise-exact. The engine is pinned to
[RayforceDB/rayforce](https://github.com/RayforceDB/rayforce) v3.0.2
by a sha256-verified installer that stages the engine's installed
headers (upstream's `make install-headers`) and cross-checks the
7-file staged tree against pinned content hashes before every build.

Part of [Jenny Stats](https://github.com/jennystats), a home for Janet
data and statistics packages. Jenny is just Janet.

## Quick start

All jenny modules install under a `jennystats/` namespace directory:
`(import jennystats/rayforce)` - collision-proof against bare-name
shadowing of core symbols or other packages, by construction.

```janet
(import jennystats/rayforce :as rayforce)

(def tbl (rayforce/table-from-columns @{:id @[1.0 2.0 3.0 4.0]
                                       :v  @[0.1 4.25 3.5 2.0]}))
(with [g (rayforce/graph tbl)]
  (def res (rayforce/execute g
    (rayforce/select g
      (rayforce/filter g
        (rayforce/const-table g tbl)
        (rayforce/gt g (rayforce/scan g "v")
                        (rayforce/const-f64 g 3.0)))
      [(rayforce/scan g "id")])))
  # @[2.0 3.0]
  (print (rayforce/table-column res "id"))  # prints the array
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
- `(table-from-packed packed &opt names)` builds a table handle
  directly from a janet-num `pack-columns-f64` handle, copy-on-ingest,
  behind a shape/byte-count guard (contract A16.1). The handle is read
  once, at guard time: a later mutation of the handle, including one
  between the guard and the build, does not affect the built table.
  `:ptr` must be the pack's Janet buffer (`:n` = `:nrow` x `:ncol`,
  `:bytes` = `8 x :nrow x :ncol`, buffer at least `:bytes` long).
- `(graph tbl)` -> graph handle; `scan`, `const-table`, arithmetic /
  comparison / logic expression ops, `filter`, `select`, `sort`,
  `group`, `distinct`, `join`, `head`, `tail`, `optimize` build the
  plan; `(execute g root)` runs it and returns a table handle.
- `(parquet-rows path &opt batch)` reads every parquet batch as an
  owned table handle (batch default 65,536 rows, the reader cap; a
  larger file arrives as several handles). Bulk f64 and i64 decode, and
  STR columns decode to Janet strings (contract A13). Every other
  column type raises `unsupported column type: <T> - deferred`. A
  DECIMAL column is refused with the engine's flat-primitive text
  (`unsupported or malformed schema (only flat primitive columns are
  supported)`); a nested schema is refused at the footer (`invalid
  Parquet footer`). Both are the module error class - loud, never
  coerced, never a shortened table. A file with zero rows yields one
  batch table of zero rows carrying the file's columns, not an empty
  array.
- **Null mapping is unified**: Janet `nil` and any NaN value are the
  same encoding in both directions (the R `is.na` semantics; the
  engine's F64 model has no separate null bitmap - an upstream design
  decision, deliberately retained). The write side collapses `nil` to
  NaN at pack time, so the mapping is asymmetric at the byte level and
  identical at the value level.
- **Input encoding**: a path or column name carrying an embedded NUL is
  refused by the marshalling layer with a core message (`bytes contain
  embedded 0s`), not the module's `rayforce:` class. The refusal is
  loud; a module-class guard at the boundary is on the post-1.0 list.
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

The behavioural specification is `specs/api-contract.md` (v1.0.7):
preconditions, ownership, the error taxonomy, null mapping and the
boundary statement above, stated contractually. The packed seam does
not verify provenance: a forged but consistently shaped handle is read
as data (contract A7.6).

## Performance

The build path is measured at every release against the gate rows in
`specs/api-contract.md` (at or under 60 ns/row at 65k rows, at or
under 40 ns/row at 1M). No cross-release comparison is claimed: such a
number depends on the host and the session it was measured in.

## Install

The module binds the engine's C ABI over ffi, so it needs the pinned
shared library (sha256-verified, idempotent):

```bash
libs/install-rayforce.sh   # rayforce v3.0.2 -> ~/.local/lib/rayforce/
```

The same run stages the headers a C client needs into
`~/.local/include` (upstream's `make install-headers` layout:
`rayforce.h` at the root plus the `rayforce/` tree), so
`-I~/.local/include -I~/.local/include/rayforce/src` is the complete
include set. Override `HEADER_DEST` to stage elsewhere; only the
`rayforce` paths under it are replaced.

Module dependencies: [janet-num](https://github.com/jennystats/janet-num)
(the packed seam - f32 handles widen to f64 columns, the `pack-columns-f64`
handle feeds `table-from-packed` - and the kernel lib the test suite
uses). The dependency is resolved at run time (`dlopen`), so there is
no build-time link and no compiled artifact: `jpm install` copies the
Janet sources and nothing else. The `typed` runtime-contract module
is provided by the [janet-kit](https://github.com/jennystats/janet-kit)
package, a declared dependency. With the library in place:

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
(DECIMAL schema, dictionary encoding, deferred types), the packed
f64 seam (gather identity, guard refusals, copy-on-ingest, error-path
cleanup), the ownership stress loop (every cycle inside the engine's
own memory trace; the pass condition is net bytes 0, alloc == free),
guard regressions (handle provenance, plan-build totality,
destructor behaviour) and the embedding statement. A second smoke
(`test/smoke-multibatch-rayforce.janet`) covers the multi-batch path:
a 100,000-row file arrives as two reader batches and the internal
batch merge rejoins them with both numeric and STR columns intact.
Both skip cleanly when librayforce or the janet-num kernel is absent;
present-but-broken is a fail, never a skip. End-to-end rayforce-query
integration coverage lives in the
[janet-query](https://github.com/jennystats/janet-query) repository, not
this suite.

Set `RAYFORCE_EXPECT_VERSION` to check the suite against a different
engine pin without editing it, e.g. the installed rollback:

```bash
# rollback check against the v2.11.5 backup:
# RAYFORCE_LIB=~/.local/lib/rayforce-v2115-rollback RAYFORCE_EXPECT_VERSION=2.11.5 ./run_tests.sh
```

## Alternatives

- [RayforceDB/rayforce](https://github.com/RayforceDB/rayforce) is the engine's own C library, the source of the pinned ABI this module binds. It is the right choice for a C or C++ program that wants the full engine without a Janet layer.
- [Faiss](https://github.com/facebookresearch/faiss) is the reference vector-search library. It covers similarity search over columnar floats; it does not expose a plan-plane graph of table ops.
- The sibling bindings [janet-duckdb](https://github.com/jennystats/janet-duckdb) and [janet-xgboost](https://github.com/jennystats/janet-xgboost) cover SQL analytics and gradient boosting respectively, and share this module's typed-contract handle style. Jenny is just Janet.

## Release notes (0.1.5)

- `table-from-packed`: build a table directly from a janet-num
  `pack-columns-f64` handle, copy-on-ingest, with the shape/byte-count
  guard (contract A16.1). The handle is read once, at guard time.
- Parquet: bulk f64/i64 decode and string (A13) support on the read
  path; DECIMAL and nested schemas are refused loudly.
- Null/NaN: NULL and NaN both decode to nil on read-back; the write side
  collapses nil to NaN at pack time (documented asymmetry).
- Known limits: a path or column name containing an embedded NUL is
  refused by the marshalling layer with a core error message rather than
  the module class (fix scheduled post-1.0); the packed seam does not
  verify provenance (A7.6 - a forged, consistently-shaped buffer is read
  as data).
- Performance: the build path is re-measured at every gate (at or under
  60 ns/row at 65k, at or under 40 ns/row at 1M); no row-level
  comparison to a parent build is claimed, because measurements taken in
  different sessions do not reproduce.

## License

AGPLv3 - see `LICENSE`. The bound Rayforce engine is MIT; its notice
ships with the upstream source pinned by the installer.

## AI assistance

The code in this repository was written with the assistance of a
large language model and reviewed by its maintainer.
