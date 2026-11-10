# smoke-rayforce.janet - the janet-rayforce conformance + ownership smoke.
#
# Cell classes: C1-C14 conformance and lifecycle checks, S1-S9 the
# ownership stress loop (each S-cell's source comment names the
# ownership.qnt action it instantiates), and the guard-regression
# cells that follow them - each a shape the guards refuse, with its
# expected error text asserted.
#
# The parquet fixtures are committed under tests/fixtures/rayforce/
# (duckdb-written flat primitives ::BIGINT/::DOUBLE - the write-side
# discipline; regenerate with libs/README recipe if absent). Engine
# notes: the engine's parquet reader rejects
# duckdb-1.5.6-written files with MIXED null/non-null columns
# ("excess definition levels") AND DICTIONARY-ENCODED columns
# ("excess dictionary indices" - dict.parquet pins it; duckdb
# dictionary-encodes low-cardinality columns by default, so null-free
# flat-primitive is necessary, not sufficient) - the fixtures are
# null-free PLAIN-encoded for that reason. The v0.1.1 STR fixtures:
# str.parquet (PLAIN STR decode, the empty-text native-null divergence),
# str-join.parquet (the string-key join table), str-null.parquet
# (mixed-null VARCHAR - an A5 rejection fixture, like dict.parquet),
# str-agg.parquet (two STR columns with repeats and empty text, PLAIN;
# the A14 agg-input fence and comparison cells), str-dict.parquet
# (dictionary-encoded VARCHAR - the A13 rejection fixture;
# duckdb default-encodes low-cardinality VARCHAR this way, which is why
# every other STR fixture must be verified PLAIN by its decode passing).
#
# Run: strict tests/smoke-rayforce.janet (requires librayforce.so +
# libjn for the packed f64 seam).

(import jennystats/typed :prefix "")
(import jennystats/rayforce :as rayforce)
(import jennystats/num)

(def cur (dyn :current-file))
(def DIR (string (or (get (os/environ) "RAYFORCE_FIXTURES")
                     (string (string/slice cur 0 (last (string/find-all "/" cur)))
                             "/fixtures/rayforce"))))

(defn assert-eq [a b msg]
  (unless (deep= a b)
    (errorf "assert %s: expected %q, got %q" msg a b)))

(defn assert-raises [f needle msg]
  (def e (try (string (f)) ([err] (string err))))
  (unless (string/find needle e)
    (errorf "assert %s: expected raise containing %q, got %q" msg needle e)))

(assert-eq [3 0 2] (rayforce/engine-version) "engine version 3.0.2")

#==------------------------------------------------------------------------==#
# Conformance cells
#==------------------------------------------------------------------------==#

# C1: f64 in-memory round-trip, bitwise (non-NaN payloads; NaN is a null
# in the engine's F64 model - contract addendum v1.0.1).
(def c1-src @[0.1 3.25 3.5 -0.0 1e300 0.0 -1e-320])
(def c1-t (rayforce/table-from-columns @{:v c1-src}))
(assert-eq c1-src (rayforce/table-column c1-t "v") "C1 f64 round-trip bitwise")
(assert-eq 7 (rayforce/table-nrows c1-t) "C1 nrows")
(assert-eq 1 (rayforce/table-ncols c1-t) "C1 ncols")
(:close c1-t)

# C2: f64 parquet round-trip vs the duckdb-written fixture (the
# cross-artifact oracle; values bitwise identical to source).
(def c2-batches (rayforce/parquet-rows (string DIR "/f64.parquet")))
(assert-eq 1 (length c2-batches) "C2 one batch")
(def c2-cols (rayforce/table-columns (first c2-batches)))
(assert-eq @[0.1 3.25 3.5 0 1e300] (c2-cols "v") "C2 parquet values bitwise")
(assert-eq @[1 2 3 4 5] (c2-cols "id") "C2 parquet ids")
(each h c2-batches (:close h))

# C3: i64 exact via the typed parquet path (the ONLY i64 entry per the
# R c() rule; ray_vec_get_i64 native lane, no double narrowing in the
# 2^53 band).
(def c3-batches (rayforce/parquet-rows (string DIR "/i64.parquet")))
(def c3-cols (rayforce/table-columns (first c3-batches)))
(assert-eq @[1099511627776 -9007199254740991 42 0] (c3-cols "big") "C3 i64 exact")
(each h c3-batches (:close h))

# C4+C5: the null mapping, unified nil<->NaN both directions (the R
# is.na semantics - engine truth: any NaN IS the null, no bitmap
# exists; read via is_null, write via set_null's NULL_F64 sentinel).
(def c4-t (rayforce/table-from-columns @{:v @[nil 1.5 (/ 0.0 0.0) math/nan 2.5]}))
(def c4-v (rayforce/table-column c4-t "v"))
(assert-eq @[nil 1.5 nil nil 2.5] c4-v "C4/C5 nil and NaN decode as nil")
(:close c4-t)

# C6: the f32 seam - janet-num packed handle widened to f64 columns;
# the pack path's NaN-encoded null arrives as a null (symmetric).
(def c6-packed (num/pack-columns-f32 [[1.5 math/nan 3.0 4.25]
                                             [0.25 0.5 math/nan 2.0]]))
(def c6-t (rayforce/table-from-columns c6-packed))
(def c6-cols (rayforce/table-columns c6-t))
(assert-eq @[1.5 nil 3.0 4.25] (c6-cols "col0") "C6 pack col0 exact widens")
(assert-eq @[0.25 0.5 nil 2.0] (c6-cols "col1") "C6 pack col1 exact widens")
(:close c6-t)

# C7: the probe's pipeline through Janet - table -> const-table ->
# filter (v > 3.0) -> select -> optimize -> execute.
(def c7-table (rayforce/table-from-columns @{:id @[1.0 2.0 3.0 4.0]
                                             :v @[0.1 3.25 3.5 2.0]}))
(def c7-g (rayforce/graph c7-table))
(def c7-node (rayforce/const-table c7-g c7-table))
(def c7-res
  (rayforce/execute c7-g
    (rayforce/optimize c7-g
      (rayforce/select c7-g
        (rayforce/filter c7-g c7-node
                         (rayforce/gt c7-g (rayforce/scan c7-g "v")
                                      (rayforce/const-f64 c7-g 3.0)))
        [(rayforce/scan c7-g "id") (rayforce/scan c7-g "v")]))))
(assert-eq 2 (rayforce/table-nrows c7-res) "C7 filtered rows")
(def c7-cols (rayforce/table-columns c7-res))
(assert-eq @[2.0 3.0] (c7-cols "id") "C7 ids")
(assert-eq @[3.25 3.5] (c7-cols "v") "C7 values")
(:close c7-res) (:close c7-g) (:close c7-table)

# add-table + scan-table (the tid source; multi-table join green).
(def mt-a (rayforce/table-from-columns @{:x @[1.0 2.0 3.0]}))
(def mt-b (rayforce/table-from-columns @{:y @[2.0 3.0 9.0]}))
(def mt-g (rayforce/graph mt-a))
(def mt-tid (rayforce/add-table mt-g mt-b))
(def mt-j (rayforce/execute mt-g
              (rayforce/join mt-g (rayforce/const-table mt-g mt-a)
                             [(rayforce/scan mt-g "x")]
                             (rayforce/const-table mt-g mt-b)
                             [(rayforce/scan-table mt-g mt-tid "y")])))
(assert-eq 2 (rayforce/table-nrows mt-j) "scan-table join rows")
(:close mt-j) (:close mt-g) (:close mt-a) (:close mt-b)

#==------------------------------------------------------------------------==#
# Deferred types (loud failure)
#==------------------------------------------------------------------------==#

# C8: STR/SYM input columns raise the deferred class (the WRITE
# side stays numeric-only, contract section 1; STR decode is READ
# paths only - v0.1.1 A13).
(assert-raises (fn [] (rayforce/table-from-columns @{:s @["x" "y"]}))
               "unsupported column type: STR - deferred"
               "C8 STR input")
(assert-raises (fn [] (rayforce/table-from-columns @{:s @[:a :b]}))
               "unsupported column type: SYM - deferred"
               "C8 SYM input")
# C9: STR parquet columns DECODE (v0.1.1, addendum A13): values are
# janet strings, byte-exact and order-preserving (inline short,
# pooled long, non-ASCII UTF-8, repeated values - the fixture is
# PLAIN-encoded; dictionary encoding remains an A5/V2-2 rejection,
# STR does not lift it). The empty text in the fixture decodes as
# nil: the upstream native-null collision (empty text -> null on
# read, rayforcedb storage docs) stated as A13's documented
# divergence from duckdb empty-string semantics.
(def c9-batches (rayforce/parquet-rows (string DIR "/str.parquet")))
(assert-eq 1 (length c9-batches) "C9 one batch")
(def c9-t (first c9-batches))
(def c9-cols (rayforce/table-columns c9-t))
(assert-eq @[1 2 3 4 5 6] (c9-cols "id") "C9 ids exact")
(assert-eq
  @[nil "x" "a long string well past twelve bytes"
    "\xC3\xBCn\xC3\xAFcod\xC3\xA9 \xE2\x80\x94 text" "x" "aaa bbb ccc"]
  (c9-cols "s")
  "C9 STR round-trip exact + empty-text -> nil divergence")
(assert-eq nil (rayforce/table-column c9-t "s0") "C9 missing column nil")
(:close c9-t)

# C9b: group-by-string-key (the load-bearing cell): the engine groups
# on its native STR representation; the module decodes group keys
# like any other column. Hand-computed: "x" appears twice (ids 2,5),
# every other key once; the empty-text null groups as nil.
(def c9b-t (first (rayforce/parquet-rows (string DIR "/str.parquet"))))
(def c9b-g (rayforce/graph c9b-t))
(def c9b-s (rayforce/scan c9b-g "s"))
(def c9b-id (rayforce/scan c9b-g "id"))
(def c9b-res (rayforce/execute c9b-g
                (rayforce/group c9b-g [c9b-s] [[c9b-id :count]])))
(assert-eq
  {"s" @[nil "x" "a long string well past twelve bytes"
         "\xC3\xBCn\xC3\xAFcod\xC3\xA9 \xE2\x80\x94 text" "aaa bbb ccc"]
   "id_count" @[1 2 1 1 1]}
  (rayforce/table-columns c9b-res)
  "C9b group-by-string-key hand-computed")
(:close c9b-res) (:close c9b-g) (:close c9b-t)

# C9c: a STR column through filter + select to the result wrapper: the
# reachable string predicate is isnull (the engine's like/ilike/
# strlen/substr/upper/lower/concat/str_find DAG constructors are NOT
# bound by this module - A13 records the boundary).
(def c9c-t (first (rayforce/parquet-rows (string DIR "/str.parquet"))))
(def c9c-g (rayforce/graph c9c-t))
(def c9c-ct (rayforce/const-table c9c-g c9c-t))
(def c9c-s (rayforce/scan c9c-g "s"))
(def c9c-res (rayforce/execute c9c-g
                (rayforce/filter c9c-g c9c-ct
                  (rayforce/isnull c9c-g c9c-s))))
(assert-eq {"id" @[1] "s" @[nil]} (rayforce/table-columns c9c-res)
            "C9c filter isnull on STR")
(:close c9c-res) (:close c9c-g) (:close c9c-t)

# C9d: join on a string key (cross-table, both key sides STR - the
# A7 join-key fence passes same-type): hand-computed matches - "x"
# twice (ids 2,5 -> v 10,10), "aaa bbb ccc" once (id 6 -> v 20).
(def c9d-t (first (rayforce/parquet-rows (string DIR "/str.parquet"))))
(def c9d-t2 (first (rayforce/parquet-rows (string DIR "/str-join.parquet"))))
(def c9d-g (rayforce/graph c9d-t))
(def c9d-tid (rayforce/add-table c9d-g c9d-t2))
(def c9d-ct (rayforce/const-table c9d-g c9d-t))
(def c9d-ct2 (rayforce/const-table c9d-g c9d-t2))
(def c9d-s (rayforce/scan c9d-g "s"))
(def c9d-k (rayforce/scan-table c9d-g c9d-tid "k"))
(def c9d-res (rayforce/execute c9d-g
                (rayforce/join c9d-g c9d-ct2 [c9d-k] c9d-ct [c9d-s])))
(def c9d-cols (rayforce/table-columns c9d-res))
# join output order is not position-stable across engine runs - the
# multiset is pinned (sorted ids), values by key checked exactly
(assert-eq @["x" "x" "aaa bbb ccc"] (c9d-cols "k") "C9d join keys")
(assert-eq @[10 10 20] (c9d-cols "v") "C9d join values")
(assert-eq @[2 5 6] (sorted (c9d-cols "id")) "C9d join ids multiset")
(:close c9d-res) (:close c9d-g) (:close c9d-t2) (:close c9d-t)

# C9e: the agg-input type fence (v0.1.1, addendum A14): :sum over a
# STR column returned
# [2 0 0 0 97 97 0], the same string summing to two different values
# in one execution, deterministic, exit 0). The numeric reducers take
# I64/F64 input ops only; the fence fires at plan-build time, before
# any engine call (the A7 join-key fence discipline).
(def c9e-t (first (rayforce/parquet-rows (string DIR "/str-agg.parquet"))))
(def c9e-g (rayforce/graph c9e-t))
(def c9e-s (rayforce/scan c9e-g "s"))
(def c9e-t2 (rayforce/scan c9e-g "t"))
(def c9e-id (rayforce/scan c9e-g "id"))
(each agg [:sum :avg :stddev :var]
  (assert-raises (fn [] (rayforce/group c9e-g [c9e-id] [[c9e-s agg]]))
                 (string/format "rayforce: group: agg %q takes I64/F64 input only, got STR" agg)
                 (string "C9e numeric agg on STR raises (" agg ")")))
# :count-distinct is fenced for ALL input types (A14): the
# pinned engine's structural group path has no count-distinct
# reducer - 0 per group on numeric input, nil on STR (v3.0.2).
(assert-raises (fn [] (rayforce/group c9e-g [c9e-id] [[c9e-s :count-distinct]]))
               "rayforce: group: :count-distinct is not served"
               "C9e count-distinct on STR raises")
(assert-raises (fn [] (rayforce/group c9e-g [c9e-id] [[c9e-id :count-distinct]]))
               "rayforce: group: :count-distinct is not served"
               "C9e count-distinct on I64 raises")
# the type-agnostic aggs accept STR and return correct values
# (single-row groups: the value itself; min/max verified byte-correct
# against duckdb ground truth on the same fixture, empty text nil).
(each agg [:count :first :last :min :max]
  (def c9e-r (rayforce/execute c9e-g (rayforce/group c9e-g [c9e-id] [[c9e-s agg]])))
  (def c9e-col
    (get (rayforce/table-columns c9e-r)
         (string "s_" (if (= agg :count) "count" agg))))
  (assert-eq (if (= agg :count) @[1 1 1 1 1 1 1]
                 @["aa" "aa" "bb" "bb" "aaa" nil nil])
             c9e-col
             (string "C9e type-agnostic agg on STR (" agg ")"))
  (:close c9e-r))
# the fence does not overfire: numeric agg over the I64 column green
(def c9e-sum (rayforce/execute c9e-g (rayforce/group c9e-g [c9e-id] [[c9e-id :sum]])))
(assert-eq {"id" @[1 2 3 4 5 6 7] "id_sum" @[1 2 3 4 5 6 7]}
           (rayforce/table-columns c9e-sum)
           "C9e numeric sum green post-fence")
(:close c9e-sum)
# C9f: the generic comparison ops on STR pairs (A13, verified
# byte-correct against duckdb on this fixture: eq selects ids 1,4,6
# - the empty-text collision compares nil=nil like duckdb ''='';
# lt selects 2,7; gt selects 3,5).
(defn c9f-sel [op]
  (def r (rayforce/execute c9e-g
            (rayforce/filter c9e-g (rayforce/const-table c9e-g c9e-t) op)))
  (def ids (sorted ((rayforce/table-columns r) "id")))
  (:close r)
  ids)
(assert-eq @[1 4 6] (c9f-sel (rayforce/eq c9e-g c9e-s c9e-t2))
            "C9f eq on STR pair")
(assert-eq @[2 7] (c9f-sel (rayforce/lt c9e-g c9e-s c9e-t2))
            "C9f lt on STR pair")
(assert-eq @[3 5] (c9f-sel (rayforce/gt c9e-g c9e-s c9e-t2))
            "C9f gt on STR pair")
(:close c9e-g) (:close c9e-t)

# C9g: dictionary-encoded STR is rejected (A13): the same
# "excess dictionary indices" rejection class as the numeric A5
# fixture - duckdb dictionary-encodes low-cardinality VARCHAR by
# default, so a consumer-side duckdb-written STR file hits this.
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/str-dict.parquet")))
               "excess dictionary indices"
               "C9g dictionary STR rejected")

#==------------------------------------------------------------------------==#
# Parquet rejection
#==------------------------------------------------------------------------==#

# C10: DECIMAL column - the engine's exact schema-rejection text.
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/decimal.parquet")))
               "unsupported or malformed schema (only flat primitive columns are supported)"
               "C10 DECIMAL rejection")
# batch guard + missing file
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/f64.parquet") 0))
               "batch must be an integer in 1..65536"
               "batch 0")
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/nope.parquet")))
               "rayforce: parquet open failed"
               "missing file")

# C11: truncated/corrupt file - SUBPROCESS cell (the mmap decoder is
# its own crash class; the child errors, the parent survives).
(defn subprobe [code]
  (def script "/tmp/rayforce-smoke-sub.janet")
  (def out "/tmp/rayforce-smoke-sub.txt")
  (spit script code)
  (def rc (os/execute ["/bin/sh" "-c"
                       (string "JANET_PATH="
                               (or (get (os/environ) "JANET_PATH") "modules:tests/lib")
                               " janet " script " > " out " 2>&1")]))
  (def msg (string/trim (string (slurp out))))
  (when (os/stat out) (os/rm out))
  (when (os/stat script) (os/rm script))
  [rc msg])

(def c11-src (string DIR "/f64.parquet"))
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(try (let [b (rayforce/parquet-rows \"" c11-src "\" 2)]\n"
  "       (print \"child read \" (length b) \" batches\"))\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "child read" msg) (string/find "child survived" msg))
          (string "C11 small-batch read survives: rc " rc ": " msg)))

# the truncated fixture for C11: a header-valid, body-corrupt copy of
# the f64 fixture (mid-file truncation - the mmap decoder's own crash
# class; the cell runs the read in a child and asserts a clean raise).
(def c11-fix "/tmp/rayforce-truncated.parquet")
(spit c11-fix (string/slice (slurp (string DIR "/f64.parquet")) 0 100))

(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(try (rayforce/parquet-rows \"/tmp/rayforce-truncated.parquet\")\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "invalid Parquet footer" msg)
               (string/find "child survived" msg))
          (string "C11 truncated file: rc " rc ": " msg)))

#==------------------------------------------------------------------------==#
# Ownership stress loop (S cells)
# Each cycle runs inside the engine's own memory trace; the pass
# condition is net-bytes == 0 (alloc == free). Every cell names the
# ownership.qnt action it instantiates - the spec is the oracle, the
# cells are the empirical trace (test-plan section 5).
#==------------------------------------------------------------------------==#

(defn net0 [thunk tag]
  (def [net allocs frees res] (rayforce/-trace-net thunk))
  (assert (and (zero? net) (= allocs frees))
          (string tag ": expected net 0 with alloc==free, got net " net
                  " (" allocs " allocs, " frees " frees) - "
                  (string/format "%q" res)))
  net)

# S1: build/add/read/release cycle.             ownership.qnt: releaseValue + consumeOk
(net0 (fn []
  (var t (rayforce/err! (rayforce/ray_table_new 1) "s1"))
  (def vec (rayforce/-vec-from-column @[1.0 2.0 nil] "s1"))
  (def id (rayforce/ray_sym_intern "s1c" 3))
  (set t (rayforce/err! (rayforce/ray_table_add_col t id vec) "s1 add"))
  (rayforce/ray_release vec)  # the wrapper's own ref; the engine retains its
  (def col (rayforce/ray_table_get_col t id))  # BORROWED (table.c:211)
  (rayforce/decode-column col 3 "s1")
  (rayforce/ray_release t))
  "S1 build/add/read/release")

# S2: add-col error path, wrong-type col (a non-vec atom) - the error
# object is error_freed, nothing else released.
#                                                ownership.qnt: freeError + consumeFail
(net0 (fn []
  (def t (rayforce/err! (rayforce/ray_table_new 1) "s2"))
  (def bad (rayforce/ray_sym_str (rayforce/ray_sym_intern "s2c" 3)))
  (def e (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s2n" 3) bad))
  (rayforce/err! e "s2 bad add")  # raises inside; the thunk's error is the cell's own catch
  nil)
  "S2 add-col error wrong-type col")

# S3: add-col error with a real table built in-cycle - the error path
# is CLEAN (the engine consumes the table, frees the error; the
# contract v1.0.1 addendum retracts the old 64 B retain row - it was
# the C probe's own unreleased atom).   ownership.qnt: consumeFail
(net0 (fn []
  (var t (rayforce/err! (rayforce/ray_table_new 1) "s3"))
  (def vec (rayforce/-vec-from-column @[5.0 6.0] "s3"))
  (set t (rayforce/err! (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s3c" 3) vec) "s3"))
  (rayforce/ray_release vec)
  (def bad (rayforce/ray_sym_str (rayforce/ray_sym_intern "s3c2" 4)))
  (def e (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s3n" 3) bad))
  (rayforce/err! e "s3 bad add")
  nil)
  "S3 add-col error real table (clean error path)")

# S4: execute cycle - release result, free graph after.
#                                                ownership.qnt: releaseValue
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:id @[1.0 2.0 3.0 4.0]}))
  (def g (rayforce/graph tbl))
  (def res (rayforce/execute g (rayforce/const-table g tbl)))
  (def n (rayforce/table-nrows res))
  (:close res) (:close g) (:close tbl)
  n)
  "S4 execute cycle")

# S5: execute error path (engine-side error object freed by err!) - the
# scan-of-missing shape now raises at construction (A8), so the cell
# drives the engine error via a group key from a NON-bound table
# (engine domain error at execute; both ops are validly built).
#                                                ownership.qnt: freeError
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:a @[1.0 2.0]}))
  (def other (rayforce/table-from-columns @{:b @[9.0]}))
  (def g (rayforce/graph tbl))
  (def tid (rayforce/add-table g other))
  (def r (try (rayforce/execute g
                 (rayforce/group g [(rayforce/scan-table g tid "b")]
                                 [[(rayforce/scan g "a") :sum]]))
               ([e] e)))
  (:close g) (:close tbl) (:close other)
  r)
  "S5 execute error path")

# S6: parquet open-to-EOF cycle - every batch released, reader closed.
#                                                ownership.qnt: releaseValue
(net0 (fn []
  (def batches (rayforce/parquet-rows (string DIR "/f64.parquet") 2))
  (def n (length batches))
  (each h batches (:close h))
  n)
  "S6 parquet open-to-EOF")

# S9: the STR decode path (v0.1.1): open, decode every column to
# janet strings, close - net 0 (the engine pool lives and dies with
# the table handle; the copied janet strings are janet-owned, outside
# the engine's accounting).
(net0 (fn []
  (def batches (rayforce/parquet-rows (string DIR "/str.parquet")))
  (def ncols
    (do (def h (first batches))
        (def cols (rayforce/table-columns h))
        (each k (keys cols) (length (cols k)))
        (length cols)))
  (each h batches (:close h))
  ncols)
  "S9 parquet STR decode cycle")

# S7: double-close attempts - the closed flag makes every second
# close a no-op.
#                                                ownership.qnt: partition/noZombie
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:a @[1.0]}))
  (def g (rayforce/graph tbl))
  (:close tbl) (:close tbl)
  (:close g) (:close g)
  nil)
  "S7 double-close")

#==------------------------------------------------------------------------==#
# Red-first guard regressions (R cells)
# The observed pre-guard red shapes are recorded in the outcome:
#   R1 stale-release counterfactual: ABSENT as a crash - the engine's
#      rc-guard absorbs the stale release (20/20 cycles net 0, no
#      downstream corruption); the cell-drop guard stands on the
#      consumeFail protocol, not on a reproducible crash.
#   R2 double free: child segfault pre-guard (ray_graph_free twice).
#   R3 forged packed handle: silent garbage values (12.0784... from
#      0x41 bytes) or out-of-range reads pre-guard.
#   R4 ragged columns: silently accepted (nrows=3 for a 2-row column,
#      phantom 0 value) pre-guard.
#==------------------------------------------------------------------------==#

# R4: the equal-length guard (the engine accepts ragged adds
# silently).                                     ownership.qnt: consumeOk belt
(assert-raises (fn [] (rayforce/table-from-columns @[[1.0 2.0 3.0] [10.0 20.0]] ["a" "b"]))
               "ragged columns"
               "R4 ragged input raises")

# R3: the packed-seam provenance guard.
(assert-raises (fn [] (rayforce/table-from-columns @{:ptr (buffer/new-filled 64 65)
                                                     :nrow 8 :ncol 1}))
               "shape mismatch"
               "R3 forged packed handle raises")
(assert-raises (fn [] (rayforce/table-from-columns @"garbage bytes"))
               "expected packed f32 handle"
               "R3 plain buffer raises")

# R1: the stale-release impossibility is asserted by S2/S3's net 0
# (ownership.qnt consumeFail): the wrapper continues from each
# consuming call's RETURN and raises on error paths without touching
# the consumed ref - the counterfactual release is structurally
# absent from the wrapper (see table-from-columns' add-col loop).

#==------------------------------------------------------------------------==#
# Lifecycle cells
#==------------------------------------------------------------------------==#

# C12: double close no-op on table + graph handles.
(def c12-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def c12-g (rayforce/graph c12-t))
(:close c12-t) (:close c12-t)
(:close c12-g) (:close c12-g)
(print "ok - C12 double close idempotent")

# C13: close-then-use raises on every wrapper-visible path.
(assert-raises (fn [] (rayforce/table-nrows c12-t)) "table already closed" "C13 table")
(assert-raises (fn [] (rayforce/table-columns c12-t)) "table already closed" "C13 table-columns")
(assert-raises (fn [] (rayforce/scan c12-g "a")) "graph already closed" "C13 graph scan")
(assert-raises (fn [] (rayforce/graph c12-t)) "table already closed" "C13 graph over closed table")
(assert-raises (fn [] (rayforce/parquet-rows 5)) "expected a file path" "parquet type-guard")
(assert-raises (fn [] (rayforce/table-nrows "not a table")) "expected table handle" "table type-guard")

# R2: double-close of a graph handle WITHOUT the closed flag is a
# double free - the pre-guard red was predicted as a child segfault,
# but is OBSERVED BENIGN under this build's allocator (double
# ray_graph_free survives, 50-graph churn after it stays clean; the
# closed-flag guard stands on the noZombie protocol, not on a
# reproducible crash). The lane stays as a watchdog: a future engine
# build whose allocator stops absorbing the double free fails here.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0]}))\n"
  "(def g (rayforce/graph t))\n"
  "(rayforce/ray_graph_free (get g :ptr))\n"
  "(rayforce/ray_graph_free (get g :ptr))\n"
  "(print \"child survived double free\")"))]
  (assert (= rc 0)
          (string "R2 raw double free (watchdog: benign on this build): rc " rc ": " msg)))

# C14: the embedding statement's enforcement - ray_eval_str is not
# resolvable through the module (no defbind exists), and the module
# document carries the embedding statement.
(def c14-env
  (first (filter |(string/find "jennystats/rayforce" (string $))
                 (keys module/cache))))
(assert c14-env "C14: the rayforce module must be loaded")
(def rf-env (get module/cache c14-env))
(assert (nil? (get rf-env 'ray_eval_str))
        "C14: ray_eval_str must not be resolvable through the module")
(assert (nil? (get rf-env 'ray_parse))
        "C14: ray_parse must not be resolvable through the module")
(assert (nil? (get rf-env 'ray_eval))
        "C14: ray_eval must not be resolvable through the module")
(def c14-doc (get rf-env :doc))
(assert (and (string? c14-doc) (string/find "EMBEDDING STATEMENT" c14-doc)
             (string/find "NEVER EXPOSED" c14-doc))
        "C14: the module documentation carries the embedding statement")

#==------------------------------------------------------------------------==#
# Guard-regression cells: names count and type, the cross-type join
# key fence, the unknown-agg guard, the container fence, the execute
# root shape, the out-of-band i64 band, BOOL result decoding and the
# packed-seam buffer accounting.
#==------------------------------------------------------------------------==#

# names length must match the column count exactly (short names
# silently DROPPED columns).
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0 2.0] @[30.0 40.0]] ["a"]))
               "names length (1) does not match column count (2)"
               "names shorter than the column count raise")
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] ["a" "b" "c"]))
               "names length (3) does not match column count (2)"
               "names longer than the column count raise")
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] ["a" :b]))
               "names must be strings"
               "non-string names raise")

# the cross-type join-key fence - the engine compares join keys
# by raw payload; mixed F64/I64 keys silently dropped non-zero
# matches. Row-wise expressions coerce correctly; the fence is
# pairwise on the ops' inferred output types.
(def f1d-i64 (first (rayforce/parquet-rows (string DIR "/i64.parquet"))))
(def f1d-g (rayforce/graph f1d-i64))
(def f1d-f64 (rayforce/table-from-columns @{:v @[1.0 2.0 42.0 0.0]}))
(def f1d-tid (rayforce/add-table f1d-g f1d-f64))
(assert-raises (fn [] (rayforce/join f1d-g (rayforce/const-table f1d-g f1d-i64)
                                     [(rayforce/scan f1d-g "big")]
                                     (rayforce/const-table f1d-g f1d-f64)
                                     [(rayforce/scan-table f1d-g f1d-tid "v")]))
               "key 0 mixes I64 and F64 columns"
               "mixed join key types raise")
(def f1d-res (rayforce/execute f1d-g
                 (rayforce/join f1d-g (rayforce/const-table f1d-g f1d-i64)
                                [(rayforce/scan f1d-g "big")]
                                (rayforce/const-table f1d-g f1d-i64)
                                [(rayforce/scan f1d-g "big")])))
(assert-eq 4 (rayforce/table-nrows f1d-res) "same-type join green")
(:close f1d-res) (:close f1d-g) (:close f1d-i64) (:close f1d-f64)

# the unknown-agg guard raises the module class (the `keys` param
# shadowed the core fn and leaked a raw janet error).
(def f4-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def f4-g (rayforce/graph f4-t))
(assert-raises (fn [] (rayforce/group f4-g [(rayforce/scan f4-g "a")]
                                       [[(rayforce/scan f4-g "a") :bogus]]))
               "rayforce: group: unknown agg :bogus"
               "F4 module error text")
(def f4-res (rayforce/execute f4-g
                (rayforce/group f4-g [(rayforce/scan f4-g "a")]
                               [[(rayforce/scan f4-g "a") :sum]])))
(assert-eq 2 (rayforce/table-nrows f4-res) "group green post-rename")
(:close f4-res) (:close f4-g) (:close f4-t)

# S8: the group error path leak-counted (ownership.qnt: freeError).
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:a @[1.0 2.0]}))
  (def g (rayforce/graph tbl))
  (def r (try (rayforce/group g [(rayforce/scan g "a")]
                              [[(rayforce/scan g "a") :bogus]])
              ([e] e)))
  (:close g) (:close tbl)
  r)
  "S8 group error path")

# struct-value and array-element container fence (a struct value
# that is not a column array iterated as BYTES: "abc" ->
# @[97 98 99]).
(assert-raises (fn [] (rayforce/table-from-columns @{:a "abc"}))
               "struct value for column a must be a column array, got string"
               "struct string value raises as a non-array column")
(assert-raises (fn [] (rayforce/table-from-columns @{:a @{:b 1}}))
               "struct value for column a must be a column array"
               "nested struct value raises as a non-array column")
(assert-raises (fn [] (rayforce/table-from-columns @[5]))
               "columns must be arrays, got number"
               "non-array column raises")

# execute's root must be table-node shaped (a bare column op
# returned a silent empty table).
(def f2f-t (rayforce/table-from-columns @{:v @[1.0 2.0]}))
(def f2f-g (rayforce/graph f2f-t))
(assert-raises (fn [] (rayforce/execute f2f-g (rayforce/scan f2f-g "v")))
               "root must be a table node"
               "bare scan root is refused")
(assert-raises (fn [] (rayforce/execute f2f-g (rayforce/const-f64 f2f-g 1.0)))
               "root must be a table node"
               "const root is refused")
(:close f2f-g) (:close f2f-t)

# an out-of-band i64 value raises the typed band error (raw
# core error); in-band i64 stays exact (C3 above).
(def f2d-b (rayforce/parquet-rows (string DIR "/i64-out-of-band.parquet")))
(assert-raises (fn [] (rayforce/table-column (first f2d-b) "big"))
               "outside the double-safe band"
               "out-of-band i64 raises the band error")
(each h f2d-b (:close h))

# BOOL result columns decode (comparison ops were unreadable
# without it; select auto-names the derived column _e0).
(def f3d-t (rayforce/table-from-columns @{:v @[1.0 2.5 0.5]}))
(def f3d-g (rayforce/graph f3d-t))
(def f3d-res (rayforce/execute f3d-g
    (rayforce/select f3d-g (rayforce/const-table f3d-g f3d-t)
                     [(rayforce/gt f3d-g (rayforce/scan f3d-g "v")
                                   (rayforce/const-f64 f3d-g 1.0))])))
(assert-eq @[false true false] (get (rayforce/table-columns f3d-res) "_e0")
           "BOOL result column decodes")
(:close f3d-res) (:close f3d-g) (:close f3d-t)

# the packed-seam boundary is SHAPE-validated (a consistent
# forged struct is indistinguishable by shape - the contract states
# the true boundary); the short-buffer lane raises up front instead
# of the raw ffi error.
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 8 65)
                          :nrow 4 :ncol 1 :n 4 :bytes 16}))
               "buffer is 8 bytes, claims 16"
               "short packed buffer is refused up front")

#==------------------------------------------------------------------------==#
# Handle-provenance and plan-totality cells: a graph-kind handle over
# a table pointer segfaulted in a subprocess; a table-kind handle over
# a graph pointer returned silent 0/nil; the i64 band leaked raw core
# errors at 2^53+1 and 1e300; nil plan arrays leaked core errors; a
# select projection returned silent empty or narrowed tables;
# duplicate names were accepted with diverging accessors; the
# dictionary-parquet rejection was undocumented.
#==------------------------------------------------------------------------==#

# V2-1a: forged GRAPH-kinded handle over a real table pointer - the
# unguarded shape SEGFAULTED (exit 139), so the cell runs in a child
# and asserts a clean module raise.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0]}))\n"
  "(try (rayforce/scan @{:ptr (get t :ptr) :kind :graph :closed false} \"a\")\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "child caught: rayforce:" msg)
               (string/find "child survived" msg))
          (string "V2-1a forged graph over table ptr raises (no 139): rc " rc ": " msg)))

# V2-1b: forged TABLE-kinded handle over a real graph pointer - the
# unguarded shape returned silent garbage (nrows 0, nil column)
# through every table-taking path; every path raises the provenance
# class.
(def v2-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def v2-g (rayforce/graph v2-t))
(def v2-forged @{:ptr (get v2-g :ptr) :kind :table :closed false})
(assert-raises (fn [] (rayforce/table-nrows v2-forged))
               "table handle provenance check failed"
               "V2-1b forged table over graph ptr (nrows)")
(assert-raises (fn [] (rayforce/table-column v2-forged "a"))
               "table handle provenance check failed"
               "V2-1b forged table over graph ptr (column)")
(assert-raises (fn [] (rayforce/const-table v2-g v2-forged))
               "table handle provenance check failed"
               "V2-1b forged table over graph ptr (const-table)")
(assert-raises (fn [] (rayforce/add-table v2-g v2-forged))
               "table handle provenance check failed"
               "V2-1b forged table over graph ptr (add-table)")
(assert-raises (fn [] (rayforce/graph v2-forged))
               "table handle provenance check failed"
               "V2-1b forged table over graph ptr (graph)")
# and the graph-side token: a struct that passes shape but was not
# constructed here
(assert-raises (fn [] (rayforce/scan @{:ptr (get v2-g :ptr) :kind :graph :closed false} "a"))
               "graph handle provenance check failed"
               "V2-1a forged graph over graph ptr raises (token)")

# V2-3/D5: const-i64 band - the unguarded shape leaked the raw core
# error "can not convert number ... to 64 bit signed integer".
(assert-raises (fn [] (rayforce/const-i64 v2-g 9007199254740993))
               "outside the double-safe band"
               "V2-3 const-i64 at 2^53+1 raises typed")
(assert-raises (fn [] (rayforce/const-i64 v2-g 1.0e300))
               "outside the double-safe band"
               "V2-3 const-i64 at 1e300 raises typed")
(assert (rayforce/const-i64 v2-g 9007199254740992)
        "V2-3 const-i64 band edge 2^53 builds")

# D4: const-bool accepted a string silently (a TRUE constant from
# "truthy").
(assert-raises (fn [] (rayforce/const-bool v2-g "truthy"))
               "rayforce: const-bool: expected a boolean"
               "V2-D4 const-bool string raises")
(assert (rayforce/const-bool v2-g nil) "V2-D4 const-bool nil stays false-lane")

# V2-D2: select-projection totality - the unguarded shapes returned a
# SILENT empty table (typo'd projection), a silently NARROWED table
# (good+missing) and an empty table (empty projection).
(assert-raises (fn [] (rayforce/scan v2-g "nope"))
               "column \"nope\" not found in the source table"
               "V2-D2 scan of a missing column raises at construction")
(def v2-node (rayforce/const-table v2-g v2-t))
(assert-raises (fn [] (rayforce/select v2-g v2-node
                                        [(rayforce/scan v2-g "a") (rayforce/scan v2-g "missing")]))
               "column \"missing\" not found in the source table"
               "V2-D2 narrowed projection raises")
(assert-raises (fn [] (rayforce/select v2-g v2-node []))
               "cols must be a non-empty array of ops"
               "V2-D2 empty projection raises")
(def v2-other (rayforce/table-from-columns @{:y @[1.0 2.0]}))
(def v2-tid (rayforce/add-table v2-g v2-other))
(assert-raises (fn [] (rayforce/scan-table v2-g v2-tid "nope"))
               "column \"nope\" not found in the source table"
               "V2-D2 scan-table of a missing column raises")

# V2-D4: nil/non-array plan-array arguments leaked RAW core errors
# ("expected iterable type, got nil" from -op-ids/each/length).
(assert-raises (fn [] (rayforce/select v2-g v2-node nil))
               "rayforce: select: cols must be a non-empty array of ops, got nil"
               "V2-D4 select nil cols")
(assert-raises (fn [] (rayforce/select v2-g v2-node 5))
               "rayforce: select: cols must be a non-empty array of ops, got number"
               "V2-D4 select number cols")
(assert-raises (fn [] (rayforce/group v2-g [(rayforce/scan v2-g "a")] nil))
               "rayforce: group: aggs must be an array"
               "V2-D4 group nil aggs")
(assert-raises (fn [] (rayforce/group v2-g nil @[]))
               "rayforce: group: keys must be an array"
               "V2-D4 group nil keys")
(assert-raises (fn [] (rayforce/distinct v2-g nil))
               "rayforce: distinct: keys must be an array"
               "V2-D4 distinct nil keys")
(assert-raises (fn [] (rayforce/sort v2-g v2-node nil))
               "rayforce: sort: keys must be an array"
               "V2-D4 sort nil keys")
(assert-raises (fn [] (rayforce/join v2-g v2-node nil v2-node nil))
               "rayforce: join: lkeys/rkeys must be arrays of ops"
               "V2-D4 join nil key arrays")

# V2-4/D3 constructor side: duplicate names were accepted (the
# two read paths then disagreed - see the D3 pin cell below).
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0 2.0] @[10.0 20.0]] ["a" "a"]))
               "duplicate column name \"a\""
               "V2-4 duplicate names raise")

# V2-D3 accessor pin: a duplicate-named table cannot be built through
# the public constructor any more, but engine-sourced tables (parquet,
# raw add_col) can carry them - pin WHICH column each accessor
# resolves (table-column the FIRST by interned id, table-columns the
# LAST by struct-key collapse). Built through the module's raw lane,
# the S-cell pattern.
(var d3-t (rayforce/err! (rayforce/ray_table_new 2) "d3"))
(def d3-id (rayforce/ray_sym_intern "a" 1))
(def d3-vec1 (rayforce/-vec-from-column @[1.0 2.0] "d3"))
(set d3-t (rayforce/err! (rayforce/ray_table_add_col d3-t d3-id d3-vec1) "d3"))
(rayforce/ray_release d3-vec1)
(def d3-vec2 (rayforce/-vec-from-column @[10.0 20.0] "d3"))
(set d3-t (rayforce/err! (rayforce/ray_table_add_col d3-t d3-id d3-vec2) "d3"))
(rayforce/ray_release d3-vec2)
(def d3-h (rayforce/make-table d3-t))
(assert-eq @[1 2] (rayforce/table-column d3-h "a")
            "D3 pin: table-column resolves the FIRST same-named column")
(assert-eq @[10 20] (get (rayforce/table-columns d3-h) "a")
            "D3 pin: table-columns keeps the LAST same-named column")
(:close d3-h)

# V2-2: dictionary-encoded parquet rejection (the engine's reader -
# duckdb dictionary-encodes any low-cardinality column by default;
# null-free flat-primitive is necessary, not sufficient - addendum A5).
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/dict.parquet")))
               "excess dictionary indices"
               "V2-2 dictionary-encoded parquet rejection documented")

# A13-N: mixed null/non-null STR parquet stays an A5 rejection (probed
# on VARCHAR across compression and row-group variants, 2026-10-19:
# "excess definition levels" - true Parquet NULLs cannot reach the STR
# decode through a duckdb-written file; the A13 null-mapping lane is
# the engine-native empty-text collision instead).
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/str-null.parquet")))
               "excess definition levels"
               "A13-N mixed-null STR parquet rejection documented (A5)")

# V2-7: guard-message and shape nits - the non-array names message
# reported a placeholder length (-1); -check-packed accepted
# negative nrow/ncol/bytes; the packed-input names message misstated
# the condition.
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] "ab"))
               "names must be an array of 2 strings, got string"
               "V2-7 non-array names message names the type")
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 4 65) :nrow -1 :ncol 1 :n -1 :bytes -4}))
               "shape mismatch (nrow -1"
               "V2-7 negative packed shape rejected")
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 4 65) :nrow 1 :ncol 1 :n 1 :bytes 4}
                        @["p" "q"]))
               "a names argument is not accepted alongside packed input"
               "V2-7 packed-input names message")

#==------------------------------------------------------------------------==#
# Registry-identity cells: a token-copy forgery over a table pointer
# segfaulted with exit 139; the same shape over a FREED graph pointer
# ran to completion, exit 0, with silent garbage; the live cross-swap
# passed; a forged op :id reached the engine; D3/D4 leaked raw core
# conversion errors; D5/D6/D7 produced misdirected messages; const-i64
# nil raised without the module prefix.
#==------------------------------------------------------------------------==#

# V3-1a: forged graph-kind handle over a table pointer WITH the copied
# provenance token - the unguarded shape SEGFAULTED (exit 139), so
# the cell runs in a child and asserts the clean module raise.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0 3.0]}))\n"
  "(def g (rayforce/graph t))\n"
  "(def forged @{:ptr (get t :ptr) :kind :graph :closed false\n"
  "              :prov (get g :prov) :bound (get t :ptr) :tables @[]})\n"
  "(try (rayforce/scan forged \"a\")\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "child caught: rayforce: graph handle provenance" msg)
               (string/find "child survived" msg))
          (string "V3-1a token-copy forgery over table ptr raises (no 139): rc " rc ": " msg)))

(def v3-t (rayforce/table-from-columns @{:a @[1.0 2.0 3.0]}))
(def v3-g (rayforce/graph v3-t))
(def v3-tok (get v3-g :prov))

# V3-1b: the UAF lane - close the genuine graph, then the forged
# shape over the FREED pointer (token copied before close, no
# allocator reuse in between): exit 0, silent garbage, no guard.
(def v3-freed-ptr (get v3-g :ptr))
(:close v3-g)
(assert-raises (fn [] (rayforce/scan
                        @{:ptr v3-freed-ptr :kind :graph :closed false
                          :prov v3-tok :bound (get v3-t :ptr) :tables @[]} "a"))
               "not the registered live graph"
               "V3-1b forged shape over a freed graph ptr raises (registry cleared on close)")

# V3-1c: cross-swap of two LIVE genuine graphs - a forged copy of
# graph A's fields carrying graph B's pointer: passed without the
# registry (one token legitimised all pointers).
(def v3-t2 (rayforce/table-from-columns @{:a @[10.0 20.0]}))
(def v3-g1 (rayforce/graph v3-t2))
(def v3-g2 (rayforce/graph v3-t2))
(assert-raises (fn [] (rayforce/scan
                        @{:ptr (get v3-g2 :ptr) :kind :graph :closed false
                          :prov (get v3-g1 :prov) :bound (get v3-t2 :ptr)
                          :tables @[(get v3-t2 :ptr)]} "a"))
               "not the registered live graph"
               "V3-1c cross-swap of two live graphs raises")
(:close v3-g2) (:close v3-g1) (:close v3-t2)

# V3-D2: forged op :id - a genuine graph, an op whose :id is the
# table block pointer: the shape-only check let it reach the engine's
# op paths (silently wrong values observed).
(def v3-g (rayforce/graph v3-t))
(assert-raises (fn [] (rayforce/add v3-g {:graph v3-g :id (get v3-t :ptr)}
                                    {:graph v3-g :id (get v3-t :ptr)}))
               "op provenance check failed"
               "V3-D2 forged op id over a table ptr raises")

# V3-D3: head/tail band - 2^53 exactly builds (clamped); beyond it
# the unguarded shape leaked the raw ffi conversion error.
(assert (rayforce/head v3-g (rayforce/const-table v3-g v3-t) 9007199254740992)
        "V3-D3 head at 2^53 exactly builds")
(assert-raises (fn [] (rayforce/head v3-g (rayforce/const-table v3-g v3-t) 9007199254740994))
               "no greater than 2^53"
               "V3-D3 head at 2^53+2 raises typed")
(assert-raises (fn [] (rayforce/tail v3-g (rayforce/const-table v3-g v3-t) 1e18))
               "no greater than 2^53"
               "V3-D3 tail at 1e18 raises typed")

# V3-D4: scan-table integrality - a fractional in-range tid previously
# leaked the raw :uint16 conversion error; tid 1 stays valid.
(def v3-t3 (rayforce/table-from-columns @{:y @[4.0 5.0]}))
(def v3-tid1 (rayforce/add-table v3-g v3-t3))
(assert-raises (fn [] (rayforce/scan-table v3-g 1.5 "y"))
               "must be an integer in [0, 65534]"
               "V3-D4 scan-table fractional tid raises typed")
(assert (rayforce/scan-table v3-g v3-tid1 "y")
        "V3-D4 scan-table integer tid 1 builds")

# V3-3: const-i64 nil previously raised the typed-contract message
# without the rayforce: prefix.
(assert-raises (fn [] (rayforce/const-i64 v3-g nil))
               "rayforce: const-i64: expected a number, got nil"
               "V3-3 const-i64 nil raises the module class")

# V3-D5: a nil-valued struct column @{:a nil} - janet containers DROP
# nil-valued keys (struct and table alike; probed: length 0), so the
# input IS empty and "no columns" is the true condition (the arm's
# iterate-keys fix is vacuous - keys never contain the entry). The
# contract states the semantics; the cell pins them.
(assert-raises (fn [] (rayforce/table-from-columns @{:a nil}))
               "rayforce: table-from-columns: no columns"
               "V3-D5 nil-valued struct column: the key vanishes, empty is the true condition")

# V3-D6: sort descs/nulls-first coerced non-boolean elements through
# truthiness; the const-bool precedent rejects them.
(assert-raises (fn [] (rayforce/sort v3-g (rayforce/const-table v3-g v3-t)
                                     [(rayforce/scan v3-g "a")] [5]))
               "descs must be a boolean array, got a number element"
               "V3-D6 sort non-boolean descs element raises")

# V3-D7: packed-like input missing :nrow once fell through to
# the struct branch with a misdirecting container message.
(assert-raises (fn [] (rayforce/table-from-columns
                       @{:ptr (buffer/new-filled 8 65) :ncol 1 :n 4 :bytes 16}))
               "packed-like input has :ptr but is missing :nrow"
               "V3-D7 packed-like input missing :nrow names the condition")

# V3-2: expression group-key result columns carry an EMPTY name from
# the engine (values correct - addendum A9 states the naming rule).
(def v3-res (rayforce/execute v3-g
    (rayforce/group v3-g [(rayforce/gt v3-g (rayforce/scan v3-g "a")
                                       (rayforce/const-f64 v3-g 1.0))]
                    [[(rayforce/scan v3-g "a") :sum]])))
(def v3-cols (rayforce/table-columns v3-res))
(assert (not (nil? (get v3-cols ""))) "V3-2 expression group-key column carries the empty name")
(assert-eq @[false true] (get v3-cols "")
            "V3-2 expression group-key column values correct")
(:close v3-res) (:close v3-t3) (:close v3-t)

#==------------------------------------------------------------------------==#
# Destructor and registry-identity cells: an extracted graph closer
# over a forged self segfaulted with exit 139; the mutated-owned-handle
# :ptr-then-close shape segfaulted with exit 139; the extracted table
# closer over a forged self carrying a graph pointer exited 0 with the
# release REDIRECTED off the argument's field (the silent-wrong-free
# lane); op-registry injection past check-op was possible through the
# public mutable :ops field.
#==------------------------------------------------------------------------==#

# V4-1a: the extracted graph closer over a forged self - the unguarded
# shape passed (get self :ptr) to ray_graph_free and SEGFAULTED; the
# closure now frees only its construction-captured pointer and only
# while its handle is the registered live graph: the forged call closes
# the GENUINE graph once and every later use raises the module class.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0 3.0]}))\n"
  "(def g (rayforce/graph t))\n"
  "(def closer (get g :close))\n"
  "(closer @{:ptr (get t :ptr) :kind :graph :closed false})\n"
  "(try (rayforce/scan g \"a\") ([e] (print \"caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "caught: rayforce: graph already closed" msg)
               (string/find "child survived" msg))
          (string "V4-1a extracted closer over forged self - no 139, genuine graph closed once: rc " rc ": " msg)))

# V4-1b: mutate an owned handle's :ptr, then close - the unguarded shape
# read the mutated field at close time and freed it (exit 139); the
# closure now frees the captured genuine pointer: no 139, the handle
# reports closed, later use raises.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0 3.0]}))\n"
  "(def g (rayforce/graph t))\n"
  "(put g :ptr (get t :ptr))\n"
  "((get g :close) g)\n"
  "(try (rayforce/scan g \"a\") ([e] (print \"caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "caught: rayforce: graph already closed" msg)
               (string/find "child survived" msg))
          (string "V4-1b mutated :ptr then close - frees the captured pointer, no 139: rc " rc ": " msg)))

# V4-1c: the extracted TABLE closer over a forged self carrying a GRAPH
# pointer - without the fix the release followed the forged field onto the
# graph block (exit 0, silent wrong free, L6-1); the closure now frees
# only its construction-captured table pointer: the table handle closes,
# and the graph block was never touched (the graph stays fully usable).
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0]}))\n"
  "(def g (rayforce/graph t))\n"
  "(def closer (get t :close))\n"
  "(closer @{:ptr (get g :ptr) :kind :table :closed false})\n"
  "(try (rayforce/table-nrows t) ([e] (print \"caught: \" e)))\n"
  "(def c (rayforce/scan g \"a\"))\n"
  "(print \"graph usable \" (truthy? c))\n"
  "(:close g)\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "caught: rayforce: table already closed" msg)
               (string/find "graph usable true" msg)
               (string/find "child survived" msg))
          (string "V4-1c table closer over forged self - free unredirectable, graph block untouched: rc " rc ": " msg)))

# V4-F1: op-registry injection - a single (put (get g :ops)
# <ptr> true) admitted a forged op past check-op (both arms); the
# registry now lives module-side (graph-state) and the public :ops
# field is gone: the old injection shape puts an INERT field and
# the forged op still raises the provenance class.
(def v4-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def v4-g (rayforce/graph v4-t))
(assert (nil? (get v4-g :ops)) "the op registry is not a public handle field")
(put v4-g :ops @{(get v4-t :ptr) true})
(assert-raises (fn [] (rayforce/add v4-g {:graph v4-g :id (get v4-t :ptr)}
                                    {:graph v4-g :id (get v4-t :ptr)}))
               "op provenance check failed"
               "the pre-registry injection shape does not admit a forged op")
(:close v4-g) (:close v4-t)

#==------------------------------------------------------------------------==#
# Plan-array and error-path cells: a non-array sort descs/nulls-first
# reached the length match and leaked the raw core error ("expected
# string, symbol, keyword, array, tuple, table, struct or buffer, got
# true"); a mid-loop raise in table-from-columns stranded the
# accumulated engine table, 192-320 bytes per failed call, error path
# only.
#==------------------------------------------------------------------------==#

# The optional plan-array guard (the A8.4 pattern) -
# descs/nulls-first join the guarded plan-array family.
(def v6-t (rayforce/table-from-columns @{:a @[3.0 1.0 2.0]}))
(def v6-g (rayforce/graph v6-t))
(def v6-node (rayforce/const-table v6-g v6-t))
(assert-raises (fn [] (rayforce/sort v6-g v6-node
                                    [(rayforce/scan v6-g "a")] true))
               "rayforce: sort: descs must be a boolean array, got boolean"
               "V6-R1 sort non-array descs raises the module class")
(assert-raises (fn [] (rayforce/sort v6-g v6-node
                                    [(rayforce/scan v6-g "a")] [false] 5))
               "rayforce: sort: nulls-first must be a boolean array, got number"
               "V6-R1 sort non-array nulls-first raises the module class")
(:close v6-g) (:close v6-t)

# the add-col-loop error-path cleanup - without it the
# deferred-type element fence mid-loop stranded the partially built
# engine table; the cleanup releases the wrapper's blocks before
# re-raising, so the raise path nets 0 (first-column and third-column
# failure lanes).
(net0 (fn []
  (try (rayforce/table-from-columns @{:a @["x"]}) ([e] e)))
  "V6-R2 first-column element failure nets 0")
(net0 (fn []
  (try (rayforce/table-from-columns
        @{:a @[1.0 2.0] :b @[3.0 4.0] :c @["x" "y"]}) ([e] e)))
  "V6-R2 third-column element failure nets 0")

#==------------------------------------------------------------------------==#
# Packed f64 seam - gather cells (K0-K6)
# K4 (the kernel never allocates) is the janet-num kernel ABI fact, cited
# from specs/kernel-abi.md sections 1-2; the compare side is the copy the
# engine makes in ray_vec_from_raw, so there is no executable cell.
#==------------------------------------------------------------------------==#

(defn double-from-bits [bits]
  "A double carrying the given IEEE-754 bit pattern."
  (def b (buffer/new-filled 8 0))
  (ffi/write @[:uint64 1] @[(int/u64 bits)] b 0)
  (ffi/read :double b))

(defn raw-bytes [xs]
  "A double array's raw bytes (the bitwise oracle for a gathered column)."
  (def b (buffer/new-filled (* 8 (length xs)) 0))
  (when (pos? (length xs)) (ffi/write @[:double (length xs)] xs b 0))
  (string b))

# K0: the internal gather exists and returns one buffer per column.
(def k0-cols @[@[1.0 2.0] @[3.0 4.0] @[5.0 6.0]])
(def k0-packed (num/pack-columns-f64 k0-cols))
(def k0-bufs (rayforce/-packed-f64-columns k0-packed))
(assert-eq 3 (length k0-bufs) "K0 one buffer per column")
(each b k0-bufs (assert-eq 16 (length b) "K0 buffer is nrow x 8 bytes"))

# K1: gather vs the pure-Janet oracle, bitwise, NaN payloads preserved,
# at 65k x 1, x 3 and x 8.
(each ncol [1 3 8]
  (def nrow 65000)
  (def cols
    (seq [c :range [0 ncol]]
      (def col (seq [r :range [0 nrow]] (* 1.0 r (+ 1 c))))
      (put col 7 (double-from-bits (string "0x7ff80000000000" (string/format "%02x" (+ 1 c)))))
      (put col 12345 (double-from-bits (string "0xfff80000000000" (string/format "%02x" (+ 1 c)))))
      col))
  (def packed (num/pack-columns-f64 cols))
  (def bufs (rayforce/-packed-f64-columns packed))
  (each c (range ncol)
    (assert (= (raw-bytes (cols c)) (string (bufs c)))
            (string "K1 gather bitwise col " c " of " ncol ": nan payloads preserved"))))

# K2: zero length and shape mismatches are refused before the kernel call.
(def k2-buf (buffer/new-filled 64 0))
(each [tag shape]
  [[:zero-row @{:ptr k2-buf :n 0 :bytes 0 :nrow 0 :ncol 1}]
   [:zero-col @{:ptr k2-buf :n 0 :bytes 0 :nrow 1 :ncol 0}]
   [:n-mismatch @{:ptr k2-buf :n 3 :bytes 16 :nrow 2 :ncol 1}]
   [:bytes-mismatch @{:ptr k2-buf :n 2 :bytes 15 :nrow 2 :ncol 1}]
   [:negative @{:ptr k2-buf :n 2 :bytes 16 :nrow -2 :ncol -1}]
   [:non-integral @{:ptr k2-buf :n 2 :bytes 16 :nrow 2.5 :ncol 1}]]
  (assert-raises (fn [] (rayforce/-packed-f64-columns shape))
                 "rayforce:" (string "K2 " tag)))

# K3: the source handle stays reachable across the call; a GC-pressure
# cell (16 columns x 200k rows, the janet-num suite shape) does not crash.
(def k3-cols (seq [c :range [0 16]] (seq [r :range [0 200000]] (* 1.0 (+ r c)))))
(def k3-packed (num/pack-columns-f64 k3-cols))
(def k3-bufs (rayforce/-packed-f64-columns k3-packed))
(gccollect)
(for _ 0 200 (buffer/new-filled 65536 0))
(assert (= (raw-bytes (k3-cols 0)) (string (k3-bufs 0)))
        "K3 first column survives GC pressure")
(assert (= (raw-bytes (k3-cols 15)) (string (k3-bufs 15)))
        "K3 last column survives GC pressure")

# K5: the resolved symbol is non-null, the pinned signature round-trips
# a known row, and resolution runs once per process (not per gather).
(var k5-count 0)
(rayforce/-set-jn-resolver (fn [] (++ k5-count) (rayforce/real-jn-resolver)))
(def k5-packed (num/pack-columns-f64 @[@[1.0 2.0 3.0] @[4.0 5.0 6.0]]))
(rayforce/-packed-f64-columns k5-packed)
(rayforce/-packed-f64-columns k5-packed)
(assert (= 1 k5-count) "K5 resolution runs once per process")
(assert (not (nil? (rayforce/-resolve-jn))) "K5 resolved symbol is non-null")
(def k5-bufs (rayforce/-packed-f64-columns k5-packed))
(assert (= (raw-bytes @[1.0 2.0 3.0]) (string (k5-bufs 0))) "K5 known row col0")
(assert (= (raw-bytes @[4.0 5.0 6.0]) (string (k5-bufs 1))) "K5 known row col1")
(rayforce/-set-jn-resolver nil)

# K6: the lazy resolution failure path raises the module class naming the
# jn_deinterleave_f64 floor and the janet-num acquisition instructions, both
# for an absent library and for a library without the kernel symbol.
(rayforce/-set-jn-resolver (fn [] nil))
(def k6-err (try (string (rayforce/-packed-f64-columns k5-packed)) ([e] (string e))))
(assert (string/find "rayforce:" k6-err) (string "K6 absent lib is the module class: " k6-err))
(assert (string/find "jn_deinterleave_f64" k6-err) (string "K6 absent lib names the kernel floor: " k6-err))
(assert (string/find "https://github.com/jennystats/janet-num" k6-err) (string "K6 absent lib gives actionable acquisition instructions: " k6-err))
(rayforce/-set-jn-resolver (fn [] (ffi/native (rayforce/lib-path))))
(def k6b-err (try (string (rayforce/-packed-f64-columns k5-packed)) ([e] (string e))))
(assert (string/find "jn_deinterleave_f64" k6b-err) (string "K6 missing symbol names the floor: " k6b-err))
(rayforce/-set-jn-resolver nil)

#==------------------------------------------------------------------------==#
# Packed f64 seam - build cells (T-I1a..b/c, T-I2a..g, T-I3a..d,
# T-I4a..c, T-E1)
#==------------------------------------------------------------------------==#

# T-I1a: build, then overwrite the source buffer; the table is unchanged.
(def t-i1-cols @[@[1.0 2.0 3.0] @[4.0 5.0 6.0]])
(def t-i1-packed (num/pack-columns-f64 t-i1-cols))
(def t-i1-t (rayforce/table-from-packed t-i1-packed))
(def t-i1-before (rayforce/table-columns t-i1-t))
(ffi/write @[:double 6] @[9.0 9.0 9.0 9.0 9.0 9.0] (get t-i1-packed :ptr) 0)
(assert-eq t-i1-before (rayforce/table-columns t-i1-t)
           "T-I1a table independent of source mutation")
(assert-eq 3 (rayforce/table-nrows t-i1-t) "T-I1a nrows after mutation")
(:close t-i1-t)

# T-I1b: build, then drop the handle and collect; the table is unchanged.
(def t-i1b-t (let [p (num/pack-columns-f64 @[@[1.0 2.0] @[3.0 4.0]])]
               (rayforce/table-from-packed p)))
(gccollect)
(for _ 0 500 (buffer/new-filled 4096 0))
(gccollect)
(assert-eq @[1.0 2.0] (rayforce/table-column t-i1b-t "col0")
           "T-I1b table survives handle collection")
(assert-eq @[3.0 4.0] (rayforce/table-column t-i1b-t "col1")
           "T-I1b second column survives handle collection")
(:close t-i1b-t)

# T-I1c: build, then drop all references to the temp buffers (the caller
# never holds them) under collection plus allocation pressure.
(def t-i1c-t (rayforce/table-from-packed (num/pack-columns-f64 @[@[0.5 1.5] @[2.5 3.5]])))
(for _ 0 200 (gccollect) (buffer/new-filled 65536 0))
(assert-eq @[0.5 1.5] (rayforce/table-column t-i1c-t "col0")
           "T-I1c temp-buffer collection leaves the table intact")
(:close t-i1c-t)

# T-I2a: every non-handle form raises the module class.
(each [tag bad]
  [[:nil nil]
   [:number 5]
   [:string "x"]
   [:array @[@[1.0]]]
   [:buffer (buffer/new-filled 8 0)]
   [:missing-ptr @{:nrow 1 :ncol 1 :n 1 :bytes 8}]
   [:raw-pointer @{:ptr (ffi/native (rayforce/lib-path)) :nrow 1 :ncol 1 :n 1 :bytes 8}]]
  (assert-raises (fn [] (rayforce/table-from-packed bad))
                 "rayforce:" (string "T-I2a " tag)))

# T-I2b: an f32 handle (4-byte accounting) raises the wrong-dtype class.
(assert-raises (fn [] (rayforce/table-from-packed (num/pack-columns-f32 @[@[1.0 2.0]])))
               "packed handle is f32"
               "T-I2b f32 handle refused, not widened")

# T-I2c: zero length raises the zero-length class.
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 8 0) :n 0 :bytes 0 :nrow 0 :ncol 1}))
               "zero length" "T-I2c zero rows")
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 8 0) :n 0 :bytes 0 :nrow 1 :ncol 0}))
               "zero length" "T-I2c zero columns")

# T-I2d: inconsistent accounting, a negative dimension, and a short buffer.
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 64 0) :n 3 :bytes 16 :nrow 2 :ncol 1}))
               "shape mismatch" "T-I2d :n inconsistent")
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 64 0) :n 2 :bytes 15 :nrow 2 :ncol 1}))
               "shape mismatch" "T-I2d :bytes inconsistent")
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 64 0) :n 2 :bytes 16 :nrow -2 :ncol -1}))
               "shape mismatch" "T-I2d negative dimension")
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 8 0) :n 2 :bytes 16 :nrow 2 :ncol 1}))
               "short buffer" "T-I2d short buffer")

# T-I2e: non-integral dimensions raise the shape class.
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 64 0) :n 2 :bytes 16 :nrow 2.5 :ncol 1}))
               "shape mismatch" "T-I2e non-integral nrow")
(assert-raises (fn [] (rayforce/table-from-packed
                       @{:ptr (buffer/new-filled 64 0) :n 2 :bytes 16 :nrow 2 :ncol 1.5}))
               "shape mismatch" "T-I2e non-integral ncol")

# T-I2f: a buffer longer than :bytes builds; the tail is ignored.
(def t-i2f-buf (buffer/new-filled 24 0))
(ffi/write @[:double 2] @[1.0 2.0] t-i2f-buf 0)
(def t-i2f-t (rayforce/table-from-packed
               @{:ptr t-i2f-buf :n 2 :bytes 16 :nrow 2 :ncol 1}))
(assert-eq @[1.0 2.0] (rayforce/table-column t-i2f-t "col0")
           "T-I2f longer buffer builds, tail ignored")
(:close t-i2f-t)

# T-I2g: the failing injected resolver is seen through the public entry.
(def t-i2g-packed (num/pack-columns-f64 @[@[1.0 2.0]]))
(rayforce/-set-jn-resolver (fn [] nil))
(def t-i2g-err (try (string (rayforce/table-from-packed t-i2g-packed)) ([e] (string e))))
(assert (string/find "jn_deinterleave_f64" t-i2g-err)
        (string "T-I2g public entry names the floor: " t-i2g-err))
(assert (string/find "https://github.com/jennystats/janet-num" t-i2g-err)
        (string "T-I2g public entry gives actionable acquisition instructions: " t-i2g-err))
(rayforce/-set-jn-resolver nil)

# T-I3a: a successful call returns a table handle with the right shape and
# bitwise-equal columns.
(def t-i3a-cols @[@[0.1 -0.0 1e300] @[3.25 1e-320 42.0]])
(def t-i3a-t (rayforce/table-from-packed (num/pack-columns-f64 t-i3a-cols)))
(assert-eq 3 (rayforce/table-nrows t-i3a-t) "T-I3a nrows")
(assert-eq 2 (rayforce/table-ncols t-i3a-t) "T-I3a ncols")
(assert (= (raw-bytes (t-i3a-cols 0)) (raw-bytes (rayforce/table-column t-i3a-t "col0")))
        "T-I3a col0 bitwise")
(assert (= (raw-bytes (t-i3a-cols 1)) (raw-bytes (rayforce/table-column t-i3a-t "col1")))
        "T-I3a col1 bitwise")
(:close t-i3a-t)

# T-I3b: a refused call returns no table and does not modify the source.
(def t-i3b-packed (num/pack-columns-f64 @[@[1.0 2.0]]))
(def t-i3b-before (string (get t-i3b-packed :ptr)))
(def t-i3b-res (try (rayforce/table-from-packed
                      @{:ptr (get t-i3b-packed :ptr) :n 3 :bytes 16 :nrow 2 :ncol 1})
                    ([e] e)))
(assert (not (table? t-i3b-res)) "T-I3b a refusal returns no table")
(assert (= t-i3b-before (string (get t-i3b-packed :ptr)))
        "T-I3b refusal leaves the source buffer unchanged")

# T-I3c: names count, type and duplicate guards raise; empty strings are
# accepted as in array input.
(def t-i3c-packed (num/pack-columns-f64 @[@[1.0 2.0] @[3.0 4.0]]))
(assert-raises (fn [] (rayforce/table-from-packed t-i3c-packed ["a"]))
               "names length" "T-I3c names count")
(assert-raises (fn [] (rayforce/table-from-packed t-i3c-packed ["a" :b]))
               "names must be strings" "T-I3c names type")
(assert-raises (fn [] (rayforce/table-from-packed t-i3c-packed ["a" "a"]))
               "duplicate column name" "T-I3c duplicate name")
(def t-i3c-t (rayforce/table-from-packed t-i3c-packed ["" "b"]))
(assert-eq @[1.0 2.0] (rayforce/table-column t-i3c-t "") "T-I3c empty name accepted")
(assert-eq @[3.0 4.0] (rayforce/table-column t-i3c-t "b") "T-I3c second name")
(:close t-i3c-t)

# T-I3d: absent names produce col0..colN-1.
(def t-i3d-t (rayforce/table-from-packed (num/pack-columns-f64 @[@[1.0] @[2.0] @[3.0]])))
(assert-eq @[1.0] (rayforce/table-column t-i3d-t "col0") "T-I3d col0")
(assert-eq @[3.0] (rayforce/table-column t-i3d-t "col2") "T-I3d col2")
(:close t-i3d-t)

# T-I4a: a source NaN bit pattern is preserved through the seam, and the
# engine's any-NaN predicate decodes it as nil.
(def t-i4-nan (double-from-bits "0x7ff8000000000001"))
(def t-i4-packed (num/pack-columns-f64 @[@[1.0 t-i4-nan 3.0]]))
(def t-i4-bufs (rayforce/-packed-f64-columns t-i4-packed))
(assert (= (raw-bytes @[1.0 t-i4-nan 3.0]) (string (t-i4-bufs 0)))
        "T-I4a NaN payload preserved through the gather")
(def t-i4-t (rayforce/table-from-packed t-i4-packed))
(assert-eq @[1.0 nil 3.0] (rayforce/table-column t-i4-t "col0")
           "T-I4a NaN decodes as nil on read-back")
(:close t-i4-t)

# T-I4b: numeric values are bitwise identical.
(def t-i4b-vals @[0.1 -0.0 1e300 -1e-320 42.0])
(def t-i4b-t (rayforce/table-from-packed (num/pack-columns-f64 @[t-i4b-vals])))
(assert (= (raw-bytes t-i4b-vals) (raw-bytes (rayforce/table-column t-i4b-t "col0")))
        "T-I4b numeric bitwise identical")
(:close t-i4b-t)

# T-I4c: no null bitmap is invented - a present NaN reads nil, a numeric
# value does not.
(def t-i4c-t (rayforce/table-from-packed (num/pack-columns-f64 @[@[t-i4-nan 2.0]])))
(def t-i4c-col (rayforce/table-column t-i4c-t "col0"))
(assert (nil? (t-i4c-col 0)) "T-I4c present NaN reads nil")
(assert (= 2.0 (t-i4c-col 1)) "T-I4c numeric value stays present")
(:close t-i4c-t)

# T-E1: a mid-build failure leaves no stranded table or vector (the A10.3
# net-0 pattern, driven through the build-fault seam).
(def t-e1-packed (num/pack-columns-f64 @[@[1.0 2.0] @[3.0 4.0] @[5.0 6.0]]))
(net0 (fn []
        (rayforce/-set-build-fault 1)
        (try (rayforce/table-from-packed t-e1-packed) ([e] e))
        (rayforce/-set-build-fault nil))
      "T-E1 mid-build failure nets 0")
(net0 (fn []
        (def t (rayforce/table-from-packed t-e1-packed))
        (:close t))
      "T-E1 successful build and close nets 0")

# T-E2: the nil shape cells, PERMANENT guards. A check that builds its
# "nil" handle with (merge base {:n nil}) does not carry a nil at all:
# Janet's merge DROPS a nil on the right-hand side, so the handle stays
# complete and the cell proves nothing about the seam. A present nil needs `put` on a mutable table,
# and a struct literal carrying :k nil omits the key - the absent rows
# below are that separate class. Every form refuses with the module class,
# through the public entry and through the internal gather.
(defn handle-with-nil-field [base field]
  "A mutable copy of a complete handle with one field present and nil."
  (def h (table/clone base))
  (put h field nil)
  h)

(def t-e2-complete @{:ptr (buffer/new-filled 16 0) :n 2 :bytes 16 :nrow 2 :ncol 1})
(each field [:n :bytes :nrow :ncol :ptr]
  (each [kind mk] [[:struct-to-table (fn [h] (table/to-struct h))]
                   [:mutable-table (fn [h] h)]]
    (def h (mk (handle-with-nil-field t-e2-complete field)))
    (def entry (try (string (rayforce/table-from-packed h)) ([e] (string e))))
    (assert (string/find "rayforce:" entry)
            (string "T-E2 " kind " " field " nil refused with the module class, entry: " entry))
    (def gather (try (string (rayforce/-packed-f64-columns h)) ([e] (string e))))
    (assert (string/find "rayforce:" gather)
            (string "T-E2 " kind " " field " nil refused with the module class, gather: " gather))))
# The absent-:ptr class: a struct literal carrying :ptr nil OMITS the key.
(each [kind bad] [[:struct-absent-ptr @{:n 2 :bytes 16 :nrow 2 :ncol 1}]
                  [:struct-to-table-absent-ptr (table/to-struct @{:n 2 :bytes 16 :nrow 2 :ncol 1})]]
  (def entry (try (string (rayforce/table-from-packed bad)) ([e] (string e))))
  (assert (string/find "rayforce:" entry)
          (string "T-E2 " kind " refused with the module class: " entry)))
# The control: the same construction with no nil builds - the refusal above
# is the nil, not the construction.
(def t-e2-ctl (table/clone t-e2-complete))
(def t-e2-ctl-t (rayforce/table-from-packed t-e2-ctl))
(assert-eq 2 (rayforce/table-nrows t-e2-ctl-t) "T-E2 control: the complete handle builds")
(:close t-e2-ctl-t)

# T-E3: the snapshot sentence is in the public
# docstring (contract A16.1 v1.0.6 mirrors it).
(def t-e3-doc (get (dyn 'rayforce/table-from-packed) :doc))
(assert (string/find "ONCE, at guard time" t-e3-doc)
        "T-E3 docstring carries the read-once-at-guard-time sentence")

(print "rayforce smoke ok")
