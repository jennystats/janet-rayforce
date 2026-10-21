# Spec - rayforce.janet public API contract (v1.0, engine v2.11.5)

Non-prose companion specification: the canonical signatures live in the
module docstrings (with the module); this contract carries what
signatures cannot - preconditions, ownership, error taxonomy, null
mapping, UB boundaries. Binding truth: the module over `librayforce.so`
built by `libs/install-rayforce.sh` from the pinned source; external
truth: the Rayforce C ABI v2.11.5, pinned by the vendored headers
(Sources).

## 1. Surface (v1)

Every public function; names are flat, verb-noun house style. Op
handles are graph-scoped borrows (section 6), so only table handles
carry `:close`.

```
(engine-version)                      -> (major minor patch) ints
(table-from-columns cols &opt names)  -> table handle
(table-nrows tbl)                     -> int
(table-ncols tbl)                     -> int
(table-column tbl name)               -> array of values | nil (no such column)
(table-columns tbl)                   -> struct: name -> array of values
(graph tbl)                           -> graph handle
(scan g name)                         -> op
(scan-table g tid name)               -> op
(const-f64 g v) / (const-i64 g v) / (const-bool g v) -> op
(add g a b) (sub g a b) (mul g a b) (div g a b) (mod g a b) (idiv g a b) -> op
(neg g a) (not g a) (isnull g a)                  -> op
(eq g a b) (ne g a b) (lt g a b) (le g a b) (gt g a b) (ge g a b) -> op
(and g a b) (or g a b) (if g c t e) (min2 g a b) (max2 g a b) -> op
(filter g input pred)                 -> op
(select g input cols)                 -> op   (cols: array of ops)
(sort g keys &opt descs nulls-first)  -> op
(group g keys aggs)                   -> op   (aggs: array of [:op agg-op] pairs)
(distinct g keys)                     -> op
(join g left lkeys right rkeys &opt type) -> op (type :inner :left :full :anti)
(head g input n) / (tail g input n)   -> op
(optimize g root)                    -> op
(execute g root)                     -> table handle (result)
(parquet-rows path &opt batch)       -> array of table handles
```

- `table-from-columns`: `cols` is an array of column arrays or a
  struct of name -> array, or a janet-num packed f32 handle (`:ptr`
  buffer or pointer form, both accepted - the provenance guard
  [name superseded by A12.2: the seam is a SHAPE/byte-count guard,
  not a provenance check - A7.6]);
  f32 columns widen to f64, lossless. All columns must be equal
  length - the guard raises on ragged input (the engine accepts
  ragged adds silently; the wrapper does not pass them through).
- **Input column typing.** Janet number arrays build F64 columns -
  always, regardless of integrality (the R `c()` model: doubles are
  the storage type; integer storage arrives from typed sources, not
  inference). I64 columns enter v1 via parquet typed columns and
  execute results; their round-trip exactness is tested on those
  paths. Cross-type operations between F64-built and I64-loaded
  columns follow engine semantics - documented below;
  if coercion is not automatic, the cast path is named.
- **Default column names.** Array or packed-handle input without a
  `names` argument names the columns `col0..colN-1` by index (N =
  column count; the packed handle's `:ncol` for the seam). A
  `names` argument of equal length overrides by position. Struct
  input takes names from its keys; a `names` argument alongside
  struct input raises the type-guard class (explicit-argument
  conflict). Rationale: duckdb-parity - unnamed columns round-trip
  through the parquet interchange without renaming.
- `table-column` / `table-columns`: values decode per section 4
  (typed null models per column type; F64 null and NaN decode as nil).
- `sort` defaults: ascending, nulls last. `join` default type
  `:inner`. `head`/`tail` n is clamped to row count.
- `parquet-rows`: `batch` is the reader's `batch_rows` (default 65536;
  must be 1..65536 - 0 raises). Returns ALL batches as an array of
  table handles; the reader is closed before returning.
- Aggregation ops in `group`: `:sum :avg :min :max :count
  :count-distinct :first :last :stddev :var` (the v1 opcode
  set; the full agg registry is a later slice).

## 2. Ownership (published - callers need this)

Per call. "You release" = call `:close` on the
handle the call returned. Never release a handle twice; never use a
released one (section 6 UB).

| call | argument refs | return | on error |
|---|---|---|---|
| `table-from-columns` | inputs borrowed (the wrapper copies into engine vectors) | table handle, owned | nothing acquired; raises |
| `table-column`/`table-columns` | tbl borrowed | the returned array is a Janet value (copied out; the engine column ref is released internally before return [superseded by A3/A12.10: get_col returns a BORROWED ref; nothing is released on the read path]) | raises on closed handle; nil on missing name |
| `graph` | tbl borrowed | graph handle, owned | raises |
| all op constructors (`scan`, `const-*`, arithmetic, comparison, logic, `filter`, `select`, `sort`, `group`, `distinct`, `join`, `head`, `tail`, `optimize`) | g and op args borrowed; ops are graph-interior values | op (a graph-scoped borrow, NOT an owned handle) | raises; the engine returns typed error objects on wrong-shape input and the wrapper raises through |
| `execute` | g, root borrowed | result table handle, owned | raises; the engine's error object is extracted, freed and raised - the caller never sees it |
| `parquet-rows` | path borrowed | array of owned table handles | raises on open failure (schema rejection, missing file); no reader survives |
| internal add-column path (feeds `table-from-columns`) | table ref CONSUMED on every path; column ref retained (caller releases) | table (same ref, transferred through the return) | the table ref is consumed by the failed call - the wrapper drops its handle cell so a stale release cannot happen |

The add-column row is the one consuming call in the v1 surface; it is
internal (no public fn exposes it), and the transfer-through-return
rule is why: the wrapper releases exactly what each call returned,
never the handle it passed.

## 3. Error taxonomy

- One module error class, ok! shape: `rayforce: <what> failed: <err>`.
  `<err>` is the engine's ASCII error code (e.g. `type`, `domain`,
  `schema`) plus its message where present - engine errors carry codes,
  not errno. [Amended by A12.5: the `defn/typed` parameter contracts
  raise the type-guard class with their own `<fn>: arg N expected <t>,
  got <t>` message - A8.4/A9.6; two message shapes, one taxonomy.]
- Type-guard class (Janet-side argument checks): wrong argument kinds
  raise before any engine call (closed handle, non-table where a table
  is required, non-array columns, ragged columns, bad `batch` range).
- Every error-returning engine call follows one rule: check the
  RAY_IS_ERR marker, extract code + message, free the error object
  (engine rule: the generic release call is a no-op on error objects -
  the dedicated free is mandatory), raise. Callers never handle raw
  engine error objects.
- Parquet schema rejection, exact text:
  `unsupported or malformed schema (only flat primitive columns are
  supported)` - DECIMAL and any nested column raise this at open. The
  write-side discipline (cast to `::DOUBLE`, flat columns) is
  janet-duckdb's contract note.
- Malformed plans (scanning a column a table does not have, projecting
  nothing) raise typed error objects - the DAG executor is total over
  plan shapes; it does not crash on plan-level mistakes.

## 4. Null mapping (both directions, per column type)

Per-type null models in the engine (v2.11.5, `rayforce.h` null-model
comment) - there is NO per-row validity bitmap; `HAS_NULLS` is a
vector-level attribute gate (`RAY_ATTR_HAS_NULLS`,
`src/vec/vec.h:50`), never the null discriminator:

- **Read (engine -> Janet)**: `ray_vec_is_null` dispatches per type -
  F64: the whole NaN class (`x != x`, the engine's single-null float
  model); i16/i32/i64: in-band `INT*_MIN` sentinels
  (`NULL_I16/I32/I64`, `rayforce.h:548-550` - a stored `NULL_I64` is
  a null, not `INT64_MIN`); BOOL/U8: the typed-null aux bit;
  SYM/STR: canonical empty values (sym 0 / empty string). A decoded
  null becomes Janet `nil`.
- **Write (Janet -> engine)**: a Janet `nil` goes through
  `ray_vec_set_null`, which writes the type's sentinel (F64:
  `NULL_F64`; integers: their `NULL_I*` values). The wrapper never
  constructs a validity bitmap. Number arrays always build F64
  columns (the input-typing rule, section 1 - always F64; I64 write
  paths exist only via typed sources: parquet, execute results).
  - f64: `nil` writes the `NULL_F64` sentinel. Because the read
    predicate is the whole NaN class, any NaN value reads back as
    nil too - nil and NaN are the same encoding in both directions
    (the unified mapping, R `is.na` semantics).
  - i64: `nil` writes `NULL_I64`; integers pass through bit-exactly.
  - f32-packed (janet-num seam): widened to f64 before ingest; the
    pack path encodes NULL as NaN, so a NULL in the packed source
    arrives as a NaN VALUE on the rayforce side - the documented
    asymmetry of the seam stands pending the #934 semantics decision
    (the any-NaN read predicate decodes it as nil; the conservative
    statement here is the write-side fact only).

Mechanism corrected against the pinned v2.11.5 source following
upstream issue #934 (2026-10-21). The unified nil/NaN model itself is
upstream-CONFIRMED as a deliberate design decision in the same issue:
the single-null float model is retained, NaN/NA are not distinguished.
upstream issue #934 (2026-10-21); the v1.0/v1.0.1 "null bitmap"
wording described a mechanism the engine does not have.

## 5. Deferred types, loud failure

STR and SYM columns are deferred past v1 (symbol interning and
dictionary decode are a later slice). A parquet file or an input
column of string/symbol type raises
`unsupported column type: STR - deferred` (SYM likewise). It never
returns a shortened table, never skips the column, never coerces.
[Amended by A12.7: the deferred set is every parquet column type
beyond the I64/F64 flat primitives the reader supports - STR, SYM,
F32, I32 and the BOOL storage I16 observed (duckdb-written
inputs) - each raising the same loud class with
its own type name.]

## 6. Handle discipline

- Table, graph and parquet-result handles are structs with `:kind`
  (`:table` / `:graph`), `:ptr` and an idempotent `:close` - a second
  close is a no-op, and `with` works through `:close`.
  [Superseded by A10.2/A12.3: handles are janet TABLES, deliberately -
  mutable-table identity is the load-bearing fact behind the A9.1
  registry fence.]
- Ops are NOT handles: an op is a graph-scoped value (`{:graph :id}`).
  Using an op after its graph closed is the same UB class as
  close-then-use on a handle.
- The janet-num seam: packed f32 handles are accepted in buffer or
  `:ptr` form through the same provenance guard the published modules
  use - a plain buffer that is not a packed handle raises the guard
  error, never a raw pointer read. [Superseded in part by A7.6/A12.2:
  the seam is SHAPE-validated, not provenance-verified - a forged but
  consistently-shaped struct's pointer form is read as data through
  that raw pointer; a plain buffer still raises the guard error and
  reads stay bounds-checked. Deeper validation is the caller's.]
- **UB section**: after `:close`, any use of that handle (or any op of
  a closed graph) is undefined behaviour - the wrapper raises
  "rayforce: <kind> already closed" on the paths it can see (the
  closed flag), but the engine memory behind a freed graph is not
  introspectable; the discipline is the caller's act.
- **Teardown**: the engine has teardown calls in its ABI; this module
  does not bind them. Embedding teardown is process exit - individual
  resources are released via `:close`; engine-level destroy would
  invalidate every live handle in the process with no ordering the
  module could enforce. Re-initialising after activity is verified
  safe (objects survive) but pointless - the module initialises once
  per process.

## 7. Threading

No thread-safety promise: concurrent calls from multiple Janet threads
are undefined behaviour. Internal engine parallelism (its morsel
scheduler) is the engine's own affair, out of this contract's scope;
the parquet reader's public calls stay on the opening thread per the
engine's own documented rule.

## 8. Embedding statement

This module embeds the FULL Rayforce engine. The Rayfall string
evaluator is part of the binary (~10% of the engine; the DAG query
executor itself evaluates its expression arguments through it) and
cannot be removed by build or link choices. It is never exposed: no
public function evaluates a string; the parquet reader never reaches
it; only caller-constructed plan nodes feed the expression path.

## 9. CFLAGS + precision

The module's installer builds the pinned source with its own recipe:
plain portable flags (`-O2`, no `-march=native`, no fast-math family;
`RAY_VERSION` passed explicitly). Every precision claim in this
contract is a claim about THAT binary. The conformance standard is the
f64 bitwise round-trip: values written into a table and read back are
byte-identical, in-memory and through a parquet file, including NaN
payloads. Integer round-trips are exact.

## 10. Platform

Linux x86_64: built and tested. macOS: compile-plausible (headers and
flags are portable; the engine's own dependencies are libc, libm,
pthreads), not verified - no stronger claim is made. Windows: not a
goal; WSL2 is the documented route.

## 11. Version coupling

Pinned to engine v2.11.5 (tarball sha256 in
`libs/install-rayforce.sh`). The binding surface compiles against
internal headers (`ops.h`, `parquet.h`,
`heap.h`), content-hash pinned in the installer - a version
bump requires: re-verify the tarball, diff the vendored headers,
update the pins, and re-pass this contract. The public header
has so far changed additively only; the internal DAG surface is the
sharper coupling and the reason for the content-hash procedure.

## 12. Ownership protocol: Quint spec + stress loop

The binding's ownership rule is a checked protocol, not prose:

- `specs/ownership.qnt` models it (live / errLive / freed states over
  ref ids; the release rule for values, the dedicated free for error
  objects, the consuming-call transfer including the error path; the
  no-zombie and partition invariants). Verified: no violation found
  (bounded, 8 steps, 6 ref ids). The protocol tests pin both protocol
  traps: the stale handle after a consume, and the error-object
  release no-op.
- The stress loop (C-level against the pinned archive; the smoke
  suite's leak-counting cycles carry the same lanes) runs
  build/add/read/release cycles, both add-column error paths, the
  execute cycle, the execute error path, a parquet open-to-EOF cycle
  and double-close attempts, each wrapped in the engine's own memory
  trace - every cycle nets zero allocated bytes except the one
  documented engine retain below. Results, single deterministic run:
  all cycles green.
- **Engine retain, documented** (not the binding's): the failed
  add-column path retains the consumed table's 64-byte block (per
  failed call; not reclaimed by the engine's error free or its gc;
  the column ref and error object free correctly). The binding's rule
  is unchanged - release nothing after a failed consuming call - and
  the retain is bounded, 64 bytes per failed call, recorded as an
  upstream watch-item.

## 13. Change protocol + stamp

v1.0, 2026-10-16. Sections above are the v1 contract; changes land as
versioned addenda with a change line naming the section and the
evidence. The surface follows the janet-query boundary:
this module exposes the raw plan plane - no convenience wrappers; if
a compositional need appears, it belongs in janet-query, and if an
expression opcode this module lacks is needed there, it lands HERE as
an evidence-cited slice.

## Addendum v1.0.1 (2026-10-16, implementation phase)

Collected surface corrections from the v1 implementation, each
ABI-forced or settled at review (evidence cited inline). The v1.0 rows
these correct are superseded where they conflict.

### A1. Surface rows (section 1)

- `(const-table g tbl) -> op` ADDED (wraps `ray_const_table`,
  ops.h:710): the table-node constructor - `ray_filter`,
  `ray_select_op`, `ray_sort_op`, `ray_join`, `ray_head`/`ray_tail`
  take TABLE ops as inputs and no v1.0 surface fn produced one (an
  inventory omission; the reference pipeline used this exact op).
  The engine retains the table; graph close releases it. Error
  class: type-guard.
- `(add-table g tbl) -> tid` ADDED (wraps `ray_graph_add_table`,
  ops.h:860): the only table-id source - without it the surface's
  `scan-table` is uncallable. The graph retains the table; released
  at graph close. Error class: type-guard + engine error sentinel.
- `sort` REWRITTEN: `(sort g input keys &opt descs nulls-first)` -
  keys is an ARRAY of key ops, e.g.
  `(sort g node [(scan g "b") (scan g "a")] [false true])`. The ABI
  is `ray_sort_op(g, table_node, keys, descs, nulls_first, n)` - a
  table node is REQUIRED (upstream threads the pipeline root
  through it); the v1.0 signature had no input argument and could
  not reach the engine. Ownership: input op is a graph-scoped
  borrow, unchanged.
- Boolean binary ops RENAMED: `and2` / `or2` (`not` unchanged).
  `and`/`or` are core MACROS - module fns shadowing macros are the
  strict-fail class; `not` is a core FUNCTION and keeps the engine's
  name like `filter`/`sort`/`distinct`. The engine's own binary-op
  naming precedent (`ray_min2`/`ray_max2` -> `min2`/`max2`) is the
  pattern applied.
- `group` aggs pair order FIXED: each pair is `[input-op
  agg-keyword]` (e.g. `[(scan g "v") :sum]`); the wrapper
  destructures to the parallel `agg_ops`/`agg_ins` arrays.
- Input typing (section 4, ingest): `table-from-columns` builds F64
  columns from Janet number arrays - ALWAYS, regardless of
  integrality (the R c() model: doubles are the storage type;
  integer storage arrives from typed sources, never inference). I64
  columns enter v1 via parquet typed columns and execute results;
  their exactness is tested on those paths.
- Default column names FIXED: unnamed array or packed-handle input
  names columns `col0`..`colN-1` by index; an equal-length `names`
  argument overrides by position; struct input takes names from its
  keys and RAISES on a `names` argument (explicit-argument conflict).

### A2. Null mapping (section 4) - the F64 model corrected (FOLDED into section 4, v0.1.2)

> Superseded by the section 4 rewrite (2026-10-21, upstream issue
> #934): this addendum's F64 model is now the section 4 text, extended
> with the integer sentinel / HAS_NULLS mechanism and the write path.
> Kept for the v1.0.1 provenance.

For F64 the engine has NO separate null bitmap: `ray_vec_set_null`
writes the `NULL_F64` NaN sentinel into the payload and
`ray_vec_is_null` is `x != x` - ANY NaN bit pattern is a null
(vec.c:49-56, upstream's deliberate design). The v1.0 claim "a real
NaN payload stays NaN" is unimplementable. The binding ships the
UNIFIED mapping: Janet `nil` and any NaN value both decode as `nil`
on read, in both directions - the R `is.na` semantics
(`is.na(c(NA_real_, NaN))` is TRUE for both). Consequences: the f64
round-trip claim is bitwise for non-NaN payloads; the f32-seam
"documented asymmetry" (pack NULL-as-NaN arriving as a NaN VALUE) is
superseded - a pack-side NULL arrives as a null, symmetric with
plain nil input. The i64 lane is unchanged (NULL_I64 exact sentinel,
`ray_vec_get_i64` native lane).

### A3. Ownership table (section 2) - get_col is BORROWED

`ray_table_get_col` / `ray_table_get_col_idx` return BORROWED refs
(source table.c:211-234: "borrowed pointer or NULL"). The earlier
owned-row reading misattributed the header's totality docs; releasing
the borrowed ref corrupts the heap (observed: a phantom third column
in the next build). The
`table-column`/`table-columns` rows now read: tbl borrowed, values
copied out, NOTHING released on the read path.

### A4. Section 12 - the 64 B engine retain RETRACTED

The "engine retain, documented" row is withdrawn: the 64 B was the
C-level stress loop's own unreleased `ray_i64(5)` atom (32-byte atom
in a 64-byte buddy block), misattributed to the engine. Janet-side
isolation: a failed add_col with a borrowed bad-col nets 0; with a
fresh unreleased bad-col table it nets exactly the caller's own
3x64 blocks. The engine's add-col error path is CLEAN. The binding
rule is unchanged and reworded: a failed consuming call leaves
NOTHING to release - the caller drops the cell. The upstream
watch-item is withdrawn (no defect). ownership.qnt is untouched
(`consumeFail` models the binding protocol; it survives). Section
12's stress-loop claim now reads: every cycle nets zero, no
exceptions.

### A5. Parquet interchange caveat (new finding)

The engine's parquet reader REJECTS duckdb-1.5.6-written files with
MIXED null/non-null columns ("excess definition levels" - tested
across DOUBLE/BIGINT/VARCHAR, compression and row-group variants);
all-null and no-null columns read fine, as do the engine's own test
fixtures. **Extended (A8.7)**: it also REJECTS DICTIONARY-ENCODED
columns - "parquet: excess dictionary indices (column v)" verbatim
through the module's error rule, and duckdb dictionary-encodes any
low-cardinality or repeated-value column BY DEFAULT, so a null-free
flat-primitive file can still fail: null-free flat-primitive is
NECESSARY, not sufficient; PLAIN-encoded null-free flat primitives
read fine. Binding behaviour: the typed error raises through, no
crash, no wrong values. Interchange fixtures are null-free PLAIN
flat-primitive (::BIGINT/::DOUBLE) until upstream moves; this is
the live upstream watch-item (the section 12 stress loop is
unaffected).

### A6. Error text (section 3) - the message accessor

`<err>` = the engine's ASCII code PLUS its message where present.
The message half is reachable through `ray_error_msg()` (exported by
the archive, runtime.c:228, but UNDECLARED in the public header; bound by the module
for the error rule only). Parquet
rejection texts verify verbatim (e.g. "unsupported or malformed
schema (only flat primitive columns are supported)").

### A7. Boundary-guard fixes (2026-10-16)

The species was silent wrong values at typing and naming boundaries;
each fix is a boundary guard raising the validation class (regression
checks in the smoke suite; each guard's comment records the pre-fix
shape).

- **A7.1 names length**: a `names` array whose length
  differs from the column count - shorter OR longer - raises the
  validation class; short names previously built a silently
  SHORTENED table (the never-shortened rule now enforced before any
  engine call). Non-string names elements raise the same class.
- **A7.2 cross-type join keys**: the engine compares
  join keys by RAW PAYLOAD - an F64-built vs I64-loaded key pair
  silently drops every non-zero match (observed; row-wise
  expressions COERCE and work, join KEYS do not). The binding therefore FENCES:
  `join` raises the validation class on pairwise-mixed key output
  types (read from the ops' inferred `out_type`, ops.h:391); v1 has
  no cast op, so mixed-key joins cannot be built correctly - build
  both key sides in one type.
- **A7.3 execute root shape**: the root must be
  table-node shaped (const-table/filter/select/group/...); a bare
  column op as root previously returned a silent EMPTY table (the
  engine's bare vector). Now a validation raise. [Amended by A12.6:
  table-node shaped means a table-node INPUT - `filter`/`select`/
  `  head`/`tail` over a bare column scan produce a VECTOR root and
  raise this class at execute.]
- **A7.4 i64 read band**: i64 values outside the
  double-safe band [-2^53, 2^53] raise the typed validation class
  (the janet number model cannot represent them); in-band i64 stays
  exact (NULL_I64 still decodes as nil).
- **A7.5 BOOL decode**: comparison/logic ops produce
  BOOL columns; `table-column`/`table-columns` now DECODE them
  (true/false). Section 5's deferred set remains STR/SYM only -
  BOOL is a readable v1 type, not deferred.
- **A7.6 packed-seam true boundary**: the seam guard is
  SHAPE-validated (buffer-or-pointer, :n/:bytes accounting,
  buffer long enough for the claimed bytes - reads bounds-checked by
  ffi/read, no memory unsafety), NOT provenance-verified: a forged
  but consistently-shaped struct is indistinguishable from a
  janet-num pack by shape alone. Deeper validation is the caller's.
  The v1.0 "forged struct raises" wording is superseded.
- **A7.7 container fence**: `table-from-columns` struct
  VALUES and array ELEMENTS must be column arrays/tuples - a
  non-array value previously iterated as BYTES/values and built a
  silent garbage column ("abc" -> @[97 98 99]). Now the validation
  class.
- **A7.8 group error class**: the unknown-agg guard
  raised a raw janet error (a `keys` parameter shadowed the core
  fn); the parameter is renamed `group-keys` and the guard raises
  the module class. No surface change; the group error path is
  leak-counted (smoke, net 0).

Coverage notes: multi-batch parquet at
the 65536 row-group crossing is untested at scale - a planned slice
note for janet-query's read paths; the C cost baseline (~1 us/row
end-to-end, informational) is not contract.

### A8. Provenance and plan-build fixes (2026-10-17)

The species was cross-kind handle forgery and silent/leaky
boundaries at the plan-build seam; each fix is a guard or a
documented boundary, with regression checks in the smoke suite.

- **A8.1 handle provenance (supersedes
  section 6's weaker guard wording)**: `check-table`/
  `check-graph` verify provenance beyond kind + pointer-ness.
  Table handles: the pointer's engine type tag
  (`ray_obj_type` = `RAY_TABLE`, byte 18 of the 32-byte ray_t header)
  - a graph pointer or any other block under a `:table` kind raises
  the type-guard class before any engine call (pre-fix: silent
  `nrows` 0, a `nil` column, silent `const-table` acceptance).
  Graph handles: the ABI affords NO graph verification (no type tag,
  no introspection call over `ray_graph_t*`), so the constructor
  stamps a module-private provenance token and `check-graph` requires
  it - a forged `:kind :graph` struct over a table pointer raises the
  type-guard class (pre-fix: `ray_scan` over the mis-typed pointer
  SEGFAULTED, exit 139). A deliberate forgery that extracts and
  copies the token is CLOSED by the A9.1 registry - see A9.1, which
  supersedes this sentence. Ops: `check-op`'s identity match to the
  call's graph, with the provenance-verified graph guard, proves the
  op's `:graph` is a genuine handle; the op's `:id` pointer check is
  superseded by the A9.2 registry.
- **A8.2 select totality (section 3's totality now
  enforced at plan-build time)**: `scan` validates the column name
  against the graph's bound table and `scan-table` against its
  registered table (the registry is wrapper-tracked; add-table ids
  are sequential from 0), because the engine only marks an
  unknown-column scan `OP_FLAG_INVALID_SCAN` (ops.h:381) and just the
  filter/distinct executor surfaces the flag - a select
  projection of a missing column silently returned an empty or
  NARROWED table (observed pre-fix: 2 requested, 1 delivered, no error).
  A typo'd column now raises the validation class at scan time. The
  bound-table rule is the surface semantic: a column of an ADDED
  table needs `scan-table`. `select` additionally requires a
  NON-EMPTY `cols` array (section 3's "projecting nothing" - the
  engine returned a silent empty table).
- **A8.3 const lanes**: `const-i64` validates the
  double-safe band [-2^53, 2^53] beside integrality - beyond it the
  ffi conversion leaked a raw core error (observed pre-fix at 2^53+1
  and 1e300); out-of-band i64 values enter via the parquet/
  typed-source path. `const-bool` accepts booleans and `nil` only
  (`nil` reads as false); any other value raises the type-guard
  class (pre-fix: a string built a TRUE constant silently).
- **A8.4 argument class**: the `defn/typed` contract
  checks (e.g. "head: arg 2 expected :number, got :nil") are the
  type-guard class for typed parameters - they raise before any
  engine call (the head/tail `n` guard precedent). The PLAN-ARRAY
  arguments (`select` cols, `group` keys/aggs, `distinct`/`sort`
  keys, `join` lkeys/rkeys) carry explicit array guards raising the
  module class   ("... must be an array of ops, got <type>") -
  previously a nil or non-array argument leaked a raw core error
  from `-op-ids`/`each`/`length` iteration (observed pre-fix:
  "expected iterable type, got nil"). [Amended by A12.8: `sort`'s
  OPTIONAL `descs`/`nulls-first` arrays join this guarded family
  ("... must be a boolean array, got <type>") -
  the A8.4 pattern; a non-array value previously leaked the raw core length error.]
- **A8.5 duplicate names**: `table-from-columns`
  RAISES on duplicate names. The engine accepts duplicate `add_col`
  names but its two read paths then disagree: `table-column`
  resolves the FIRST same-named column (by interned id) while
  `table-columns` keeps the LAST (struct-key collapse) - a silent
  divergence at the naming boundary (observed pre-fix; the resolution
  is PINNED by cells on an engine-sourced duplicate table). The
  typed-contract model requires unique names; R tolerates
  duplicates, this stack does not. Engine-sourced tables (parquet,
  the raw lanes) may still carry duplicates; the pinned resolution
  rule applies there.
- **A8.6 guard-message and shape nits**: a non-array
  `names` argument reports its TYPE (pre-fix: a placeholder length
  of -1); `-check-packed` rejects negative `:nrow`/`:ncol`/`:bytes`
  shapes (a consistent negative shape previously built an empty
  table); the packed-input names message states the true condition
  ("a names argument is not accepted alongside packed input"); the
  module header summary matches this addendum.
- **A8.7 parquet dictionary encoding (extends A5)**: see the
  extended A5 row - the rejection text and the
  necessary-not-sufficient interchange sentence; the `dict.parquet`
  smoke fixture pins the engine's exact text. Upstream watch-note:
  the reader's null-count and dictionary-page paths.

**Addendum v1.0.1 STAMP - CLOSED 2026-10-17**: the v2-round findings
are dispositioned - each fixed or documented-with-regression-checks
per the smallest-correct-change rule. Carried forward as known v1
limits: the bound-table composition limits (aggregation over a
subquery is not expressible in v1; `scan`-of-a-non-bound-column now
raises via A8.2, but the join-row alignment footgun stays) and the
doc-precision note that parquet batches are row-group-sized, capped
at `batch`.

### A9. Provenance-registry fixes (2026-10-17)

The v2 provenance token was copyable and the pre-fix tree still had
exit 139 through it; the misuse lanes (token-copy 139, UAF silent
garbage, live cross-swap) are pinned by regression checks in the
smoke suite. The A8.1 rows this section supersedes are named
inline above.

- **A9.1 graph provenance registry (BLOCKING)**:
  `check-graph` resolves the handle through a module-side LIVE-POINTER
  REGISTRY: construction maps each graph pointer to its handle,
  `check-graph` requires registry IDENTITY - the argument must BE the
  registered handle for its pointer. No fact used by the guard is
copyable off a genuine handle (a forged or swapped handle is a
different value). Closes the pre-fix shapes:
  token-copy forgery over a table pointer (exit 139), the same shape
  over a FREED graph pointer (ran to completion, silent garbage - the
  UAF lane), cross-swap of two live genuine graphs (passed), and
  forged handles over a closed   graph's pointer (registry cleared on
  `:close`, no allocator-reuse timing involved). The v2 token
  stays as a second fence. `check-table` is unchanged (its engine
  type-tag fact already meets the same standard). Registry cost: an
  unclosed graph handle is retained module-side for the process
  lifetime (janet has no weak references) - graphs should be closed.
- **A9.2 op :id registry**: an op's `:id` must be a
  constructor-registered op of the SAME graph - a per-graph set
  reachable only through the genuine handle (`check-op` resolves
  membership after the graph's own registry check). [SUPERSEDED IN
  PART by A11.1/A12.1: the op set lives in `graph-state`, a module-env
  def reachable through `module/cache` - "reachable only through the
  genuine handle" holds AT THE API SURFACE, not against an in-process
  caller.] Supersedes A8.1's
  shape-only op sentence: a forged op `:id` (a foreign block pointer
  under a genuine graph) previously reached the engine's op paths and
  silently produced plausible-but-meaningless values; it now raises
  the op provenance class before any engine call.
- **A9.3 numeric-argument guards completed**: `head`/
  `tail` `n` carries the double-safe band clause (beyond 2^53 the
  janet ffi conversion previously leaked a raw core error; 2^53
  exactly still builds and clamps); `scan-table` `tid` carries
  integrality beside its range check (a fractional in-range tid
  previously leaked the raw `:uint16` conversion error). Both raise
  the module class.
- **A9.4 i64 read-back is all-or-nothing (A7.4 confirmation)**: one
  out-of-band value makes the WHOLE column unreadable - every value,
  in-band ones included, raises the band class on read. Deliberate:
  a partial-column return would be the silent-wrong-value class the
  rule forbids. In-band i64 stays exact.
- **A9.5 expression group-key result columns carry an empty
  name**: a `group` whose key is an expression op (not a bare
  column scan) produces a result column named `""` (values correct).
  The engine names key columns from their source; an expression has
  no source name, and the wrapper does not synthesise one - engine-
  sourced result names pass through unchanged (the `col0..colN-1`
  default applies to constructor INPUT, not engine results). Pinned
  by a smoke check.
- **A9.6 message-shape family**: `const-i64` types its value argument manually (`:any` + an explicit
  number check) so the nil case raises WITH the module prefix - the
  `defn/typed` contract class (A8.4) still governs every other typed
  parameter. A packed-LIKE map with `:ptr` but missing `:nrow`/
  `:ncol` raises a packed-detection message before the struct branch
  (previously a misdirecting container message). `sort`
  `descs`/`nulls-first` reject non-boolean ELEMENTS (the const-bool
  precedent; previously coerced via truthiness; length was already
  guarded). Settled against the suggested change: the `@{:a nil}`
  "no columns" case is NOT misdirecting - janet
  containers (struct and table alike) do not store nil-valued keys,
  so the input is literally empty; an iterate-keys change is
  vacuous. Semantics stated here instead.

### A10. Destructor-provenance fixes (2026-10-17)

The pre-fix shapes (two exit-139 destructor shapes, the exit-0
redirected release) are pinned by regression checks in the smoke
suite.

- **A10.1 destructor provenance (BLOCKING)**: every handle
  destructor frees the pointer CAPTURED AT CONSTRUCTION in the closure
  scope - the graph/table `:close` closures read nothing off their
  argument, so `self` mutation cannot redirect a free and an extracted
  closer is safe to call with ANY self shape (the pre-fix shapes:
  extracted closer over a forged self, exit 139; mutated owned
  `:ptr` then close, exit 139; table closer over a forged self carrying
  a graph ptr, exit 0 with the release redirected off the argument's
  field - a silent wrong free on a refcount). The graph destructor is
  additionally REGISTRY-GATED: it frees only while its own handle is
  still the registered live graph for the captured pointer - a second
  call through any argument shape is a no-op, and a stale closer
  cannot re-free a pointer the allocator has since handed to a new
  graph. The idempotent `:closed` flag is set on the genuine handle
  captured in the closure scope, not read from the argument.
- **A10.2 handle representation: tables, deliberately (the section-6
  structs-vs-tables contradiction resolved)**. Handles are janet
  TABLES, not structs - and this is load-bearing, not drift: janet
  structs compare by CONTENT, so a field-for-field copy of a genuine
  handle (every field, `:close` and `:prov` included, is readable and
  copyable) would be `=` to the registered handle and pass the A9.1
  registry-IDENTITY fence. Mutable-table identity is the one
  unforgeable fact in the janet value model; the handles stay tables to
  keep it. What the mutation boundary buys the caller post-fix:
  NOTHING load-bearing - the op registry, the added-table registry and
  the bound pointer moved MODULE-SIDE (graph-state, keyed by the graph
  pointer, so no public field is read by any check or destructor).
  Mutating `:ptr` or stamping an inert `:ops` field changes no check's
  outcome (pinned by a smoke check: the pre-fix injection shape now
  raises the op provenance class). [The "reachable only through
  check-graph's identity fence" sentence this row carried at v4 is
  SUPERSEDED by A11.1 - the module-env door; the field-mutation claims
  stand.]
- **A10.3 op-registry injection boundary**: post-fix a caller cannot affect op provenance by HANDLE-FIELD
  mutation - the registry is module-side and no public field feeds it.
  The pre-fix vector (a single `put` into the then-public `g.ops`)
  admitted a forged op id past check-op; the engine rejected every
  downstream probed shape, but the boundary was
  defeatable by construction and is closed at the handle.
  [SUPERSEDED IN PART by A11.1: the module-env
  door re-opens op-registry injection - `graph-state` is exported in
  the module environment, so in-process code CAN put into the ops
  registry; the field-mutation claim is untouched.]
- **A10.4 scan-table column-name validation scope**: the wrapper validates the column name against the registered table
  for REGISTERED tids only; an out-of-range or unregistered tid skips
  the wrapper-side validation and the engine's NULL-guard raises
  ("engine returned NULL") - the engine rejects unknown tids itself,
  so the skipped check is belt, not fence. Note row; no module change.

### A11. The module-env boundary (2026-10-17)

This section settles the module-env question - a suspected contract
defect in A10.2/A10.3 - with a documented boundary and the rationale
below.

- **A11.1 the boundary statement (BLOCKING -> dispositioned
  2026-10-17)**. `graph-registry` and `graph-state` are top-level
  module defs, hence exported in the module environment and reachable
  by any in-process code through the public `module/cache` table: a
  caller can `put` a forged handle into the registry, `put` a matching
  graph-state entry, and reach `ray_scan` with a table pointer - exit
  139, pinned by a smoke check (expected
  outcome: 139, BY DOCUMENTED BOUNDARY). The A10.2 "reachable only
  through check-graph's identity fence" sentence and the A10.3
  "caller CANNOT affect op provenance" sentence were false as written
  and are superseded above. The boundary the implementation verifiably
  holds, stated here as the contract: **The module's guards catch
  programming errors at the API surface - wrong-kind handles,
  use-after-close, cross-graph confusion, malformed plans; every such
  path raises (the regression checks show every misuse lane
  raising). They are not a sandbox. Code running in the process can
  reach the module's state through the module environment and the
  engine's ffi directly, and can bypass any Janet-level guard; the
  module does not attempt to defend against that caller.** The
  rationale: in-process code can
  call the `ray_*` ffi directly and forge pointers, so no Janet-level
  guard can bind a hostile in-process caller; the guards bind MISUSE at
  the API surface, and the honest contract says exactly that. Each
  earlier fence (the v2 token, the v3 copy, the v4 destructor) was
  a contract overclaiming its implementation; this row ends
  the cycle by stating the boundary the implementation verifiably
  holds. No code change rides with this disposition - the guards stay
  as they are.
- **A11.2 boundary effect on the surrounding claims**. The
  binding claims are unchanged on every
  ownership, error-rule and null-mapping row; the provenance claims
  are now scoped to the API surface (A11.1) - the module states what
  its guards verify (kind, closed, registered identity, registered op
  membership - all module-side facts checked before any engine call)
  and no longer claims module-state privacy. No licence,
  attribution, engine-pin or vendored-header change; the boundary
  statement is a scope-of-guarantee statement, not a security claim,
  and the module's AGPLv3 header and the engine's MIT notices are
  untouched.
- **A11.3 engine allocator block reuse (observation)**:
  the engine allocator immediately reuses a freed graph block for the
  next graph (pa = pb, observed directly); the registry
  identity fence is what makes this safe (a stale closer is a no-op,
  a forged-over-reuse handle raises). No module action.

### A12. Wording corrections and guard completions (2026-10-18)

This round's species is contract sentences behind the implementation,
plus two small code items; every amendment below carries its inline
mark at the amended site - no silent edits. The pre-fix shapes are
pinned by regression checks in the smoke suite.

- **A12.1 A9.2's reachability sentence**: A9.2's "reachable only through
  the genuine handle" asserted a privacy property A11.1 says does not
  hold - the op set is reachable through `module/cache` exactly like
  the graph registry (observed: an injected op id accepted at the
  engine, exit 0). Marked superseded in part at A9.2 above - the same
  correction pattern A10.2/A10.3 received.
- **A12.2 the packed seam's guard name (sections 1 and 6)**:
  sections 1 and 6 called the packed seam "the provenance guard";
  the seam has no provenance element (A7.6 superseded the v1.0
  wording, but the name survived in two places). Both sites now name
  it a shape/byte-count guard. Rides with A12.4's scope fix on the
  same section-6 sentence.
- **A12.3 handles are tables (section 6)**: section 6's
  "are structs" was the
  contradiction A10.2 resolved, left
  unmarked at its own site. Supersession bracket added; the
  load-bearing fact is mutable-table identity behind the A9.1 fence.
- **A12.4 section 6's "never a raw pointer read"**: false
  for a forged packed struct's pointer form - the seam is
  SHAPE-validated (A7.6), so a consistently-shaped forged `:ptr` form
  is read as data through that raw pointer. Scoped in place: a plain
  buffer still raises the guard error; reads stay bounds-checked;
  deeper validation is the caller's.
- **A12.5 section 3's error-class story**: "one module
  error class" understated the `defn/typed` parameter class
  (`const-f64: arg 1 expected :number, got :string`, no prefix -
  A8.4/A9.6). Amended in place: one module class for engine and
  guard errors, the typed-contract class for typed parameters - two
  message shapes, one taxonomy, every path raises.
- **A12.6 A7.3's root-shape list**: "table-node shaped
  (const-table/filter/select/group/...)" implied any `filter` root
  qualifies; `filter` over a bare column scan yields the engine's
  VECTOR and raises at execute. Amended in place: table-node shaped
  means a table-node INPUT.
- **A12.7 section 5's deferred enumeration**: the
  enumeration named only STR/SYM. Fresh duckdb-written inputs show
  F32, I32 and BOOL (stored as I16) raise the same loud deferred
  class. Amended in place to the general rule: the reader supports
  I64 and F64 flat primitive columns; every other column type
  raises `unsupported column type: <T> - deferred`. No coercion, no
  shortened table, no crash - the rule itself was already exact.
- **A12.8 sort optional-array guards (code)**:
  `sort`'s optional `descs`/`nulls-first` skipped the A8.4 array
  guard; a non-array value reached the length match and leaked a raw
  core error ("expected string, symbol, ... got true"). Both now
  carry the array guard raising the module class (the A8.4 pattern,
  joined to that family in place). Regression check in the smoke
  suite.
- **A12.9 table-from-columns error-path cleanup (bounded,
  error-path-only, code)**: a raise inside the add-col loop
  (the deferred-type element fence, typically) stranded the
  partially built engine table - net 192-320 bytes per failed call,
  module-side, attributed, no wrong values (observed: 3/0 at the
  first column, 5/0 at the third). The wrapper now releases exactly
  what it still owns before re-raising - the pending column vec on
  every error path (the column ref is the caller's per section 2)
  and the accumulated table when the raise is not the consuming
  add-col call itself (a failed `add_col` consumes the table ref;
  releasing it there would be the double-free counterfactual).
  Section 2's "on error: nothing acquired; raises" row now holds
  engine-side too. Leak-tier checks in the smoke suite pin both
  failure lanes at net 0.
- **A12.10 section 2's stale read-path wording**: the `table-column` row still
  said the engine column ref "is released internally before return";
  A3 established get_col is BORROWED and nothing is released on the
  read path. Supersession bracket added at the row.

This addendum row set is the v1.0.1 contract state.

## Sources

- `libs/install-rayforce.sh` - the engine pin (tarball sha256) and
  the vendored-header content hashes (the ABI truth, cross-checked
  before every build).
- The Rayforce C ABI v2.11.5 (the external truth).
- `specs/ownership.qnt` - the checked ownership protocol (section 12).
- The sibling contracts in this stack (janet-duckdb, janet-xgboost) -
  the specification template and the guard-taxonomy precedent.
