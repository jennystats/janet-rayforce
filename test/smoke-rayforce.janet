# smoke-rayforce.janet - the janet-rayforce conformance + ownership smoke.
#
# Sections: conformance/lifecycle checks, the ownership stress loop
# (each cycle runs inside the engine's own memory trace; the pass
# condition is net-bytes == 0, alloc == free; every cycle's comment
# names the ownership.qnt action it instantiates), and guard
# regression checks - each guard's comment records the observed
# pre-fix shape it closes.
#
# The parquet fixtures are committed under tests/fixtures/rayforce/
# (duckdb-written flat primitives ::BIGINT/::DOUBLE - the write-side
# discipline). Engine
# notes: the engine's parquet reader rejects
# duckdb-1.5.6-written files with MIXED null/non-null columns
# ("excess definition levels") AND DICTIONARY-ENCODED columns
# ("excess dictionary indices" - dict.parquet pins it; duckdb
# dictionary-encodes low-cardinality columns by default, so null-free
# flat-primitive is necessary, not sufficient) - the fixtures are
# null-free PLAIN-encoded for that reason.
#
# Run: strict test/smoke-rayforce.janet (requires librayforce.so +
# libjn for the packed f32 seam).

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

(assert-eq [2 11 5] (rayforce/engine-version) "engine version 2.11.5")

#==------------------------------------------------------------------------==#
# Conformance checks
#==------------------------------------------------------------------------==#

# f64 in-memory round-trip, bitwise (non-NaN payloads; NaN is a null
# in the engine's F64 model - contract addendum v1.0.1).
(def c1-src @[0.1 3.25 3.5 -0.0 1e300 0.0 -1e-320])
(def c1-t (rayforce/table-from-columns @{:v c1-src}))
(assert-eq c1-src (rayforce/table-column c1-t "v") "f64 round-trip bitwise")
(assert-eq 7 (rayforce/table-nrows c1-t) "nrows")
(assert-eq 1 (rayforce/table-ncols c1-t) "ncols")
(:close c1-t)

# f64 parquet round-trip vs the duckdb-written fixture (the
# cross-artifact comparison; values bitwise identical to source).
(def c2-batches (rayforce/parquet-rows (string DIR "/f64.parquet")))
(assert-eq 1 (length c2-batches) "one batch")
(def c2-cols (rayforce/table-columns (first c2-batches)))
(assert-eq @[0.1 3.25 3.5 0 1e300] (c2-cols "v") "parquet values bitwise")
(assert-eq @[1 2 3 4 5] (c2-cols "id") "parquet ids")
(each h c2-batches (:close h))

# i64 exact via the typed parquet path (the ONLY i64 entry per the
# R c() rule; ray_vec_get_i64 native lane, no double narrowing in the
# 2^53 band).
(def c3-batches (rayforce/parquet-rows (string DIR "/i64.parquet")))
(def c3-cols (rayforce/table-columns (first c3-batches)))
(assert-eq @[1099511627776 -9007199254740991 42 0] (c3-cols "big") "i64 exact")
(each h c3-batches (:close h))

# the null mapping, unified nil<->NaN both directions (the R
# is.na semantics - engine truth: any NaN IS the null, no bitmap
# exists; read via is_null, write via set_null's NULL_F64 sentinel).
(def c4-t (rayforce/table-from-columns @{:v @[nil 1.5 (/ 0.0 0.0) math/nan 2.5]}))
(def c4-v (rayforce/table-column c4-t "v"))
(assert-eq @[nil 1.5 nil nil 2.5] c4-v "nil and NaN decode as nil")
(:close c4-t)

# the f32 seam - janet-num packed handle widened to f64 columns;
# the pack path's NaN-encoded null arrives as a null (symmetric).
(def c6-packed (num/pack-columns-f32 [[1.5 math/nan 3.0 4.25]
                                             [0.25 0.5 math/nan 2.0]]))
(def c6-t (rayforce/table-from-columns c6-packed))
(def c6-cols (rayforce/table-columns c6-t))
(assert-eq @[1.5 nil 3.0 4.25] (c6-cols "col0") "pack col0 exact widens")
(assert-eq @[0.25 0.5 nil 2.0] (c6-cols "col1") "pack col1 exact widens")
(:close c6-t)

# the reference pipeline through Janet - table -> const-table ->
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
(assert-eq 2 (rayforce/table-nrows c7-res) "filtered rows")
(def c7-cols (rayforce/table-columns c7-res))
(assert-eq @[2.0 3.0] (c7-cols "id") "ids")
(assert-eq @[3.25 3.5] (c7-cols "v") "values")
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

# STR/SYM input columns raise the deferred class.
(assert-raises (fn [] (rayforce/table-from-columns @{:s @["x" "y"]}))
               "unsupported column type: STR - deferred"
               "STR input")
(assert-raises (fn [] (rayforce/table-from-columns @{:s @[:a :b]}))
               "unsupported column type: SYM - deferred"
               "SYM input")
# STR parquet column - same class on the read path.
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/str.parquet")))
               "unsupported column type: STR - deferred"
               "STR parquet")

#==------------------------------------------------------------------------==#
# Parquet rejection
#==------------------------------------------------------------------------==#

# DECIMAL column - the engine's exact schema-rejection text.
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/decimal.parquet")))
               "unsupported or malformed schema (only flat primitive columns are supported)"
               "DECIMAL rejection")
# batch guard + missing file
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/f64.parquet") 0))
               "batch must be an integer in 1..65536"
               "batch 0")
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/nope.parquet")))
               "rayforce: parquet open failed"
               "missing file")

# truncated/corrupt file - SUBPROCESS check (the mmap decoder is
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
          (string "small-batch read survives: rc " rc ": " msg)))

# the truncated fixture for C11: a header-valid, body-corrupt copy of
# the f64 fixture (mid-file truncation - the mmap decoder's own crash
# class; the check runs the read in a child and asserts a clean raise).
(def c11-fix "/tmp/rayforce-truncated.parquet")
(spit c11-fix (string/slice (slurp (string DIR "/f64.parquet")) 0 100))

(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(try (rayforce/parquet-rows \"/tmp/rayforce-truncated.parquet\")\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "invalid Parquet footer" msg)
               (string/find "child survived" msg))
          (string "truncated file: rc " rc ": " msg)))

#==------------------------------------------------------------------------==#
# Ownership stress loop
# Each cycle runs inside the engine's own memory trace; the pass
# condition is net-bytes == 0 (alloc == free). Every cycle names the
# ownership.qnt action it instantiates - the spec is the model, the
# cycles are the empirical trace.
#==------------------------------------------------------------------------==#

(defn net0 [thunk tag]
  (def [net allocs frees res] (rayforce/-trace-net thunk))
  (assert (and (zero? net) (= allocs frees))
          (string tag ": expected net 0 with alloc==free, got net " net
                  " (" allocs " allocs, " frees " frees) - "
                  (string/format "%q" res)))
  net)

# build/add/read/release cycle.             ownership.qnt: releaseValue + consumeOk
(net0 (fn []
  (var t (rayforce/err! (rayforce/ray_table_new 1) "s1"))
  (def vec (rayforce/-vec-from-column @[1.0 2.0 nil] "s1"))
  (def id (rayforce/ray_sym_intern "s1c" 3))
  (set t (rayforce/err! (rayforce/ray_table_add_col t id vec) "s1 add"))
  (rayforce/ray_release vec)  # the wrapper's own ref; the engine retains its
  (def col (rayforce/ray_table_get_col t id))  # BORROWED (table.c:211)
  (rayforce/decode-column col 3 "s1")
  (rayforce/ray_release t))
  "build/add/read/release")

# add-col error path, wrong-type col (a non-vec atom) - the error
# object is error_freed, nothing else released.
#                                                ownership.qnt: freeError + consumeFail
(net0 (fn []
  (def t (rayforce/err! (rayforce/ray_table_new 1) "s2"))
  (def bad (rayforce/ray_sym_str (rayforce/ray_sym_intern "s2c" 3)))
  (def e (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s2n" 3) bad))
  (rayforce/err! e "s2 bad add")  # raises inside; the thunk's error is the cycle's own catch
  nil)
  "add-col error wrong-type col")

# add-col error with a real table built in-cycle - the error path
# is CLEAN (the engine consumes the table, frees the error; the
# contract v1.0.1 addendum retracts the old 64 B retain row - it was
# the earlier C-level stress loop's own unreleased atom).   ownership.qnt: consumeFail
(net0 (fn []
  (var t (rayforce/err! (rayforce/ray_table_new 1) "s3"))
  (def vec (rayforce/-vec-from-column @[5.0 6.0] "s3"))
  (set t (rayforce/err! (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s3c" 3) vec) "s3"))
  (rayforce/ray_release vec)
  (def bad (rayforce/ray_sym_str (rayforce/ray_sym_intern "s3c2" 4)))
  (def e (rayforce/ray_table_add_col t (rayforce/ray_sym_intern "s3n" 3) bad))
  (rayforce/err! e "s3 bad add")
  nil)
  "add-col error real table (clean error path)")

# execute cycle - release result, free graph after.
#                                                ownership.qnt: releaseValue
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:id @[1.0 2.0 3.0 4.0]}))
  (def g (rayforce/graph tbl))
  (def res (rayforce/execute g (rayforce/const-table g tbl)))
  (def n (rayforce/table-nrows res))
  (:close res) (:close g) (:close tbl)
  n)
  "execute cycle")

# execute error path (engine-side error object freed by err!) - the
# scan-of-missing shape now raises at construction (A8.2), so the check
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
  "execute error path")

# parquet open-to-EOF cycle - every batch released, reader closed.
#                                                ownership.qnt: releaseValue
(net0 (fn []
  (def batches (rayforce/parquet-rows (string DIR "/f64.parquet") 2))
  (def n (length batches))
  (each h batches (:close h))
  n)
  "parquet open-to-EOF")

# double-close attempts - the closed flag makes every second
# close a no-op.
#                                                ownership.qnt: partition/noZombie
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:a @[1.0]}))
  (def g (rayforce/graph tbl))
  (:close tbl) (:close tbl)
  (:close g) (:close g)
  nil)
  "double-close")

#==------------------------------------------------------------------------==#
# Guard regressions (constructor and seam guards)
# The observed pre-guard shapes:
#   stale-release counterfactual: ABSENT as a crash - the engine's
#      rc-guard absorbs the stale release (20/20 cycles net 0, no
#      downstream corruption); the consumed-ref drop stands on the
#      consumeFail protocol, not on a reproducible crash.
#   double free: child segfault pre-guard (ray_graph_free twice).
#   forged packed handle: silent garbage values (12.0784... from
#      0x41 bytes) or out-of-range reads pre-guard.
#   ragged columns: silently accepted (nrows=3 for a 2-row column,
#      phantom 0 value) pre-guard.
#==------------------------------------------------------------------------==#

# the equal-length guard (the engine accepts ragged adds
# silently).                                     ownership.qnt: consumeOk belt
(assert-raises (fn [] (rayforce/table-from-columns @[[1.0 2.0 3.0] [10.0 20.0]] ["a" "b"]))
               "ragged columns"
               "ragged input raises")

# the packed-seam provenance guard.
(assert-raises (fn [] (rayforce/table-from-columns @{:ptr (buffer/new-filled 64 65)
                                                     :nrow 8 :ncol 1}))
               "shape mismatch"
               "forged packed handle raises")
(assert-raises (fn [] (rayforce/table-from-columns @"garbage bytes"))
               "expected packed f32 handle"
               "plain buffer raises")

# the stale-release impossibility is asserted by S2/S3's net 0
# (ownership.qnt consumeFail): the wrapper continues from each
# consuming call's RETURN and raises on error paths without touching
# the consumed ref - the counterfactual release is structurally
# absent from the wrapper (see table-from-columns' add-col loop).

#==------------------------------------------------------------------------==#
# Lifecycle checks
#==------------------------------------------------------------------------==#

# double close no-op on table + graph handles.
(def c12-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def c12-g (rayforce/graph c12-t))
(:close c12-t) (:close c12-t)
(:close c12-g) (:close c12-g)
(print "ok - double close idempotent")

# close-then-use raises on every wrapper-visible path.
(assert-raises (fn [] (rayforce/table-nrows c12-t)) "table already closed" "table")
(assert-raises (fn [] (rayforce/table-columns c12-t)) "table already closed" "table-columns")
(assert-raises (fn [] (rayforce/scan c12-g "a")) "graph already closed" "graph scan")
(assert-raises (fn [] (rayforce/graph c12-t)) "table already closed" "graph over closed table")
(assert-raises (fn [] (rayforce/parquet-rows 5)) "expected a file path" "parquet type-guard")
(assert-raises (fn [] (rayforce/table-nrows "not a table")) "expected table handle" "table type-guard")

# double-close of a graph handle WITHOUT the closed flag is a
# double free - the pre-guard shape was predicted as a child segfault,
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
          (string "raw double free (watchdog: benign on this build): rc " rc ": " msg)))

# the embedding statement's enforcement - ray_eval_str is not
# resolvable through the module (no defbind exists), and the module
# document carries the embedding statement.
(def c14-env
  (first (filter |(string/find "jennystats/rayforce" (string $))
                 (keys module/cache))))
(assert c14-env "the rayforce module must be loaded")
(def rf-env (get module/cache c14-env))
(assert (nil? (get rf-env 'ray_eval_str))
        "ray_eval_str must not be resolvable through the module")
(assert (nil? (get rf-env 'ray_parse))
        "ray_parse must not be resolvable through the module")
(assert (nil? (get rf-env 'ray_eval))
        "ray_eval must not be resolvable through the module")
(def c14-doc (get rf-env :doc))
(assert (and (string? c14-doc) (string/find "EMBEDDING STATEMENT" c14-doc)
             (string/find "NEVER EXPOSED" c14-doc))
        "the module documentation carries the embedding statement")

#==------------------------------------------------------------------------==#
# Guard regressions (typing and naming boundaries): silent column
# drop on short names, mixed-type join keys, raw janet error text from
# the unknown-agg guard, byte-code columns from non-array values,
# silent empty table on a bare-scan root, raw core error on
# out-of-band i64, unreadable BOOL columns - each observed pre-fix,
# closed by the guards below.
#==------------------------------------------------------------------------==#

# names length must match the column count exactly (short names
# silently DROPPED columns pre-fix).
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0 2.0] @[30.0 40.0]] ["a"]))
               "names length (1) does not match column count (2)"
               "short names")
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] ["a" "b" "c"]))
               "names length (3) does not match column count (2)"
               "long names")
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] ["a" :b]))
               "names must be strings"
               "non-string names")

# the cross-type join-key fence - the engine compares join keys
# by raw payload; mixed F64/I64 keys silently dropped non-zero matches
# pre-fix. Row-wise expressions coerce correctly; the fence is pairwise on the ops' inferred output types.
(def f1d-i64 (first (rayforce/parquet-rows (string DIR "/i64.parquet"))))
(def f1d-g (rayforce/graph f1d-i64))
(def f1d-f64 (rayforce/table-from-columns @{:v @[1.0 2.0 42.0 0.0]}))
(def f1d-tid (rayforce/add-table f1d-g f1d-f64))
(assert-raises (fn [] (rayforce/join f1d-g (rayforce/const-table f1d-g f1d-i64)
                                     [(rayforce/scan f1d-g "big")]
                                     (rayforce/const-table f1d-g f1d-f64)
                                     [(rayforce/scan-table f1d-g f1d-tid "v")]))
               "key 0 mixes I64 and F64 columns"
               "mixed join keys raise")
(def f1d-res (rayforce/execute f1d-g
                 (rayforce/join f1d-g (rayforce/const-table f1d-g f1d-i64)
                                [(rayforce/scan f1d-g "big")]
                                (rayforce/const-table f1d-g f1d-i64)
                                [(rayforce/scan f1d-g "big")])))
(assert-eq 4 (rayforce/table-nrows f1d-res) "same-type join green")
(:close f1d-res) (:close f1d-g) (:close f1d-i64) (:close f1d-f64)

# the unknown-agg guard raises the module class (the `keys` param
# shadowed the core fn and leaked a raw janet error pre-fix).
(def f4-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def f4-g (rayforce/graph f4-t))
(assert-raises (fn [] (rayforce/group f4-g [(rayforce/scan f4-g "a")]
                                       [[(rayforce/scan f4-g "a") :bogus]]))
               "rayforce: group: unknown agg :bogus"
               "module error text")
(def f4-res (rayforce/execute f4-g
                (rayforce/group f4-g [(rayforce/scan f4-g "a")]
                               [[(rayforce/scan f4-g "a") :sum]])))
(assert-eq 2 (rayforce/table-nrows f4-res) "group green post-rename")
(:close f4-res) (:close f4-g) (:close f4-t)

# the group error path leak-counted (ownership.qnt: freeError).
(net0 (fn []
  (def tbl (rayforce/table-from-columns @{:a @[1.0 2.0]}))
  (def g (rayforce/graph tbl))
  (def r (try (rayforce/group g [(rayforce/scan g "a")]
                              [[(rayforce/scan g "a") :bogus]])
              ([e] e)))
  (:close g) (:close tbl)
  r)
  "group error path")

# struct-value and array-element container fence (a struct value
# that is not a column array iterated as BYTES pre-fix: "abc" ->
# @[97 98 99]).
(assert-raises (fn [] (rayforce/table-from-columns @{:a "abc"}))
               "struct value for column a must be a column array, got string"
               "struct string value")
(assert-raises (fn [] (rayforce/table-from-columns @{:a @{:b 1}}))
               "struct value for column a must be a column array"
               "nested struct value")
(assert-raises (fn [] (rayforce/table-from-columns @[5]))
               "columns must be arrays, got number"
               "non-array column")

# execute's root must be table-node shaped (a bare column op
# returned a silent empty table pre-fix).
(def f2f-t (rayforce/table-from-columns @{:v @[1.0 2.0]}))
(def f2f-g (rayforce/graph f2f-t))
(assert-raises (fn [] (rayforce/execute f2f-g (rayforce/scan f2f-g "v")))
               "root must be a table node"
               "bare scan root")
(assert-raises (fn [] (rayforce/execute f2f-g (rayforce/const-f64 f2f-g 1.0)))
               "root must be a table node"
               "const root")
(:close f2f-g) (:close f2f-t)

# an out-of-band i64 value raises the typed band error (raw
# core error pre-fix); in-band i64 stays exact (C3 above).
(def f2d-b (rayforce/parquet-rows (string DIR "/i64-out-of-band.parquet")))
(assert-raises (fn [] (rayforce/table-column (first f2d-b) "big"))
               "outside the double-safe band"
               "out-of-band i64")
(each h f2d-b (:close h))

# BOOL result columns decode (comparison ops were unreadable
# pre-fix; select auto-names the derived column _e0).
(def f3d-t (rayforce/table-from-columns @{:v @[1.0 2.5 0.5]}))
(def f3d-g (rayforce/graph f3d-t))
(def f3d-res (rayforce/execute f3d-g
    (rayforce/select f3d-g (rayforce/const-table f3d-g f3d-t)
                     [(rayforce/gt f3d-g (rayforce/scan f3d-g "v")
                                   (rayforce/const-f64 f3d-g 1.0))])))
(assert-eq @[false true false] (get (rayforce/table-columns f3d-res) "_e0")
           "BOOL column decodes")
(:close f3d-res) (:close f3d-g) (:close f3d-t)

# the packed-seam boundary is SHAPE-validated (a consistent forged struct is indistinguishable by shape - the
# contract states the true boundary); the short-buffer lane raises
# up front instead of the raw ffi error.
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 8 65)
                          :nrow 4 :ncol 1 :n 4 :bytes 16}))
               "buffer is 8 bytes, claims 16"
               "short packed buffer")

#==------------------------------------------------------------------------==#
# Guard regressions (handle provenance and plan-build boundaries):
# each shape observed pre-fix - a graph-kind handle over a table
# pointer SEGFAULTED exit 139 in a subprocess; a table-kind handle
# over a graph pointer returned silent 0/nil; raw core errors at
# 2^53+1 and 1e300; "expected iterable type" leaks on nil plan
# arrays; silent empty/narrowed select tables; duplicate names
# accepted with diverging accessors; dictionary parquet rejection
# undocumented
#==------------------------------------------------------------------------==#

# forged GRAPH-kinded handle over a real table pointer - the
# pre-fix shape SEGFAULTED (exit 139), so the check runs in a child and
# asserts a clean module raise.
(let [[rc msg] (subprobe (string
  "(import jennystats/rayforce :as rayforce)\n"
  "(def t (rayforce/table-from-columns @{:a @[1.0 2.0]}))\n"
  "(try (rayforce/scan @{:ptr (get t :ptr) :kind :graph :closed false} \"a\")\n"
  "     ([e] (print \"child caught: \" e)))\n"
  "(print \"child survived\")"))]
  (assert (and (= rc 0) (string/find "child caught: rayforce:" msg)
               (string/find "child survived" msg))
          (string "forged graph over table ptr raises (no 139): rc " rc ": " msg)))

# forged TABLE-kinded handle over a real graph pointer - the
# pre-fix shape returned silent garbage (nrows 0, nil column) through
# every table-taking path; every path now raises the provenance class.
(def v2-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def v2-g (rayforce/graph v2-t))
(def v2-forged @{:ptr (get v2-g :ptr) :kind :table :closed false})
(assert-raises (fn [] (rayforce/table-nrows v2-forged))
               "table handle provenance check failed"
               "forged table over graph ptr (nrows)")
(assert-raises (fn [] (rayforce/table-column v2-forged "a"))
               "table handle provenance check failed"
               "forged table over graph ptr (column)")
(assert-raises (fn [] (rayforce/const-table v2-g v2-forged))
               "table handle provenance check failed"
               "forged table over graph ptr (const-table)")
(assert-raises (fn [] (rayforce/add-table v2-g v2-forged))
               "table handle provenance check failed"
               "forged table over graph ptr (add-table)")
(assert-raises (fn [] (rayforce/graph v2-forged))
               "table handle provenance check failed"
               "forged table over graph ptr (graph)")
# and the graph-side token: a struct that passes shape but was not
# constructed here
(assert-raises (fn [] (rayforce/scan @{:ptr (get v2-g :ptr) :kind :graph :closed false} "a"))
               "graph handle provenance check failed"
               "forged graph over graph ptr raises (token)")

# const-i64 band - the pre-fix shape leaked the raw core
# error "can not convert number ... to 64 bit signed integer".
(assert-raises (fn [] (rayforce/const-i64 v2-g 9007199254740993))
               "outside the double-safe band"
               "const-i64 at 2^53+1 raises typed")
(assert-raises (fn [] (rayforce/const-i64 v2-g 1.0e300))
               "outside the double-safe band"
               "const-i64 at 1e300 raises typed")
(assert (rayforce/const-i64 v2-g 9007199254740992)
        "const-i64 band edge 2^53 builds")

# const-bool accepted a string silently pre-fix (a TRUE constant
# from "truthy").
(assert-raises (fn [] (rayforce/const-bool v2-g "truthy"))
               "rayforce: const-bool: expected a boolean"
               "const-bool string raises")
(assert (rayforce/const-bool v2-g nil) "const-bool nil stays false-lane")

# select-projection totality - the pre-fix shapes returned a
# SILENT empty table (typo'd projection), a silently NARROWED table
# (good+missing) and an empty table (empty projection).
(assert-raises (fn [] (rayforce/scan v2-g "nope"))
               "column \"nope\" not found in the source table"
               "scan of a missing column raises at construction")
(def v2-node (rayforce/const-table v2-g v2-t))
(assert-raises (fn [] (rayforce/select v2-g v2-node
                                        [(rayforce/scan v2-g "a") (rayforce/scan v2-g "missing")]))
               "column \"missing\" not found in the source table"
               "narrowed projection raises")
(assert-raises (fn [] (rayforce/select v2-g v2-node []))
               "cols must be a non-empty array of ops"
               "empty projection raises")
(def v2-other (rayforce/table-from-columns @{:y @[1.0 2.0]}))
(def v2-tid (rayforce/add-table v2-g v2-other))
(assert-raises (fn [] (rayforce/scan-table v2-g v2-tid "nope"))
               "column \"nope\" not found in the source table"
               "scan-table of a missing column raises")

# nil/non-array plan-array arguments leaked RAW core errors
# pre-fix ("expected iterable type, got nil" from -op-ids/each/length).
(assert-raises (fn [] (rayforce/select v2-g v2-node nil))
               "rayforce: select: cols must be a non-empty array of ops, got nil"
               "select nil cols")
(assert-raises (fn [] (rayforce/select v2-g v2-node 5))
               "rayforce: select: cols must be a non-empty array of ops, got number"
               "select number cols")
(assert-raises (fn [] (rayforce/group v2-g [(rayforce/scan v2-g "a")] nil))
               "rayforce: group: aggs must be an array"
               "group nil aggs")
(assert-raises (fn [] (rayforce/group v2-g nil @[]))
               "rayforce: group: keys must be an array"
               "group nil keys")
(assert-raises (fn [] (rayforce/distinct v2-g nil))
               "rayforce: distinct: keys must be an array"
               "distinct nil keys")
(assert-raises (fn [] (rayforce/sort v2-g v2-node nil))
               "rayforce: sort: keys must be an array"
               "sort nil keys")
(assert-raises (fn [] (rayforce/join v2-g v2-node nil v2-node nil))
               "rayforce: join: lkeys/rkeys must be arrays of ops"
               "join nil key arrays")

# constructor side: duplicate names accepted pre-fix (the
# two read paths then disagreed - see the accessor pin below).
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0 2.0] @[10.0 20.0]] ["a" "a"]))
               "duplicate column name \"a\""
               "duplicate names raise")

# accessor pin: a duplicate-named table cannot be built through
# the public constructor any more, but engine-sourced tables (parquet,
# raw add_col) can carry them - pin WHICH column each accessor
# resolves (table-column the FIRST by interned id, table-columns the
# LAST by struct-key collapse). Built through the module's raw lane,
# the raw-lane pattern.
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
            "table-column resolves the FIRST same-named column")
(assert-eq @[10 20] (get (rayforce/table-columns d3-h) "a")
            "table-columns keeps the LAST same-named column")
(:close d3-h)

# dictionary-encoded parquet rejection (the engine's reader -
# duckdb dictionary-encodes any low-cardinality column by default;
# null-free flat-primitive is necessary, not sufficient - addendum A5).
(assert-raises (fn [] (rayforce/parquet-rows (string DIR "/dict.parquet")))
               "excess dictionary indices"
               "dictionary-encoded parquet rejection documented")

# guard-message and shape nits - the non-array names message
# reported a placeholder length (-1) pre-fix; -check-packed accepted
# negative nrow/ncol/bytes; the packed-input names message misstated
# the condition.
(assert-raises (fn [] (rayforce/table-from-columns @[@[1.0] @[2.0]] "ab"))
               "names must be an array of 2 strings, got string"
               "non-array names message names the type")
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 4 65) :nrow -1 :ncol 1 :n -1 :bytes -4}))
               "shape mismatch (nrow -1"
               "negative packed shape rejected")
(assert-raises (fn [] (rayforce/table-from-columns
                        @{:ptr (buffer/new-filled 4 65) :nrow 1 :ncol 1 :n 1 :bytes 4}
                        @["p" "q"]))
               "a names argument is not accepted alongside packed input"
               "packed-input names message")

#==------------------------------------------------------------------------==#
# Guard regressions (provenance registry and argument guards): each
# shape observed pre-fix - token-copy forgery
# over a table ptr SEGFAULTED exit 139; the same shape over a FREED
# graph ptr ran to completion, exit 0, silent garbage; the live
# cross-swap passed; a forged op :id reached the engine; fractional
# and out-of-band numeric arguments leaked raw core conversion
# errors; misdirected guard messages; const-i64 nil raised without
# the module prefix
#==------------------------------------------------------------------------==#

# forged graph-kind handle over a table pointer WITH the copied
# provenance token - the pre-fix shape SEGFAULTED (exit 139), so the
# check runs in a child and asserts the clean module raise.
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
          (string "token-copy forgery over table ptr raises (no 139): rc " rc ": " msg)))

(def v3-t (rayforce/table-from-columns @{:a @[1.0 2.0 3.0]}))
(def v3-g (rayforce/graph v3-t))
(def v3-tok (get v3-g :prov))

# the UAF lane - close the genuine graph, then the forged
# shape over the FREED pointer (token copied before close, no
# allocator reuse in between). Pre-fix: exit 0, silent garbage.
(def v3-freed-ptr (get v3-g :ptr))
(:close v3-g)
(assert-raises (fn [] (rayforce/scan
                        @{:ptr v3-freed-ptr :kind :graph :closed false
                          :prov v3-tok :bound (get v3-t :ptr) :tables @[]} "a"))
               "not the registered live graph"
               "forged shape over a freed graph ptr raises (registry cleared on close)")

# cross-swap of two LIVE genuine graphs - a forged copy of
# graph A's fields carrying graph B's pointer. Pre-fix: passed (one
# token legitimised all pointers).
(def v3-t2 (rayforce/table-from-columns @{:a @[10.0 20.0]}))
(def v3-g1 (rayforce/graph v3-t2))
(def v3-g2 (rayforce/graph v3-t2))
(assert-raises (fn [] (rayforce/scan
                        @{:ptr (get v3-g2 :ptr) :kind :graph :closed false
                          :prov (get v3-g1 :prov) :bound (get v3-t2 :ptr)
                          :tables @[(get v3-t2 :ptr)]} "a"))
               "not the registered live graph"
               "cross-swap of two live graphs raises")
(:close v3-g2) (:close v3-g1) (:close v3-t2)

# forged op :id - a genuine graph, an op whose :id is the
# table block pointer. Pre-fix: shape-only check let it reach the
# engine's op paths (silently wrong values observed).
(def v3-g (rayforce/graph v3-t))
(assert-raises (fn [] (rayforce/add v3-g {:graph v3-g :id (get v3-t :ptr)}
                                    {:graph v3-g :id (get v3-t :ptr)}))
               "op provenance check failed"
               "forged op id over a table ptr raises")

# head/tail band - 2^53 exactly builds (clamped); beyond it
# the pre-fix shape leaked the raw ffi conversion error.
(assert (rayforce/head v3-g (rayforce/const-table v3-g v3-t) 9007199254740992)
        "head at 2^53 exactly builds")
(assert-raises (fn [] (rayforce/head v3-g (rayforce/const-table v3-g v3-t) 9007199254740994))
               "no greater than 2^53"
               "head at 2^53+2 raises typed")
(assert-raises (fn [] (rayforce/tail v3-g (rayforce/const-table v3-g v3-t) 1e18))
               "no greater than 2^53"
               "tail at 1e18 raises typed")

# scan-table integrality - a fractional in-range tid previously
# leaked the raw :uint16 conversion error; tid 1 stays valid.
(def v3-t3 (rayforce/table-from-columns @{:y @[4.0 5.0]}))
(def v3-tid1 (rayforce/add-table v3-g v3-t3))
(assert-raises (fn [] (rayforce/scan-table v3-g 1.5 "y"))
               "must be an integer in [0, 65534]"
               "scan-table fractional tid raises typed")
(assert (rayforce/scan-table v3-g v3-tid1 "y")
        "scan-table integer tid 1 builds")

# const-i64 nil previously raised the typed-contract message
# without the rayforce: prefix.
(assert-raises (fn [] (rayforce/const-i64 v3-g nil))
               "rayforce: const-i64: expected a number, got nil"
               "const-i64 nil raises the module class")

# a nil-valued struct column @{:a nil} - janet containers DROP
# nil-valued keys (struct and table alike; containers drop nil-valued
# keys, so the length is 0), so the
# input IS empty and "no columns" is the true condition (an
# iterate-keys change would be vacuous - keys never contain the
# entry). The
# contract states the semantics; this check pins them.
(assert-raises (fn [] (rayforce/table-from-columns @{:a nil}))
               "rayforce: table-from-columns: no columns"
               "nil-valued struct column: the key vanishes, empty is the true condition")

# sort descs/nulls-first coerced non-boolean elements through
# truthiness pre-fix; the const-bool precedent now rejects them.
(assert-raises (fn [] (rayforce/sort v3-g (rayforce/const-table v3-g v3-t)
                                     [(rayforce/scan v3-g "a")] [5]))
               "descs must be a boolean array, got a number element"
               "sort non-boolean descs element raises")

# packed-like input missing :nrow previously fell through to
# the struct branch with a misdirecting container message.
(assert-raises (fn [] (rayforce/table-from-columns
                       @{:ptr (buffer/new-filled 8 65) :ncol 1 :n 4 :bytes 16}))
               "packed-like input has :ptr but is missing :nrow"
               "packed-like input missing :nrow names the condition")

# expression group-key result columns carry an EMPTY name from
# the engine (values correct - addendum A9 states the naming rule).
(def v3-res (rayforce/execute v3-g
    (rayforce/group v3-g [(rayforce/gt v3-g (rayforce/scan v3-g "a")
                                       (rayforce/const-f64 v3-g 1.0))]
                    [[(rayforce/scan v3-g "a") :sum]])))
(def v3-cols (rayforce/table-columns v3-res))
(assert (not (nil? (get v3-cols ""))) "expression group-key column carries the empty name")
(assert-eq @[false true] (get v3-cols "")
            "expression group-key column values correct")
(:close v3-res) (:close v3-t3) (:close v3-t)

#==------------------------------------------------------------------------==#
# Guard regressions (destructor provenance and op-registry boundary):
# each shape observed pre-fix - an extracted graph
# closer over a forged self SEGFAULTED exit 139; the
# mutated-owned-handle :ptr-then-close shape SEGFAULTED exit 139; the
# extracted table closer over a forged self carrying a graph ptr
# exit-0'd with the release REDIRECTED off the argument's field -
# the silent wrong-free lane; op-registry
# injection past check-op via the public mutable :ops field
#==------------------------------------------------------------------------==#

# the extracted graph closer over a forged self - the pre-fix
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
          (string "extracted closer over forged self - no 139, genuine graph closed once: rc " rc ": " msg)))

# mutate an owned handle's :ptr, then close - the pre-fix shape
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
          (string "mutated :ptr then close - frees the captured pointer, no 139: rc " rc ": " msg)))

# the extracted TABLE closer over a forged self carrying a GRAPH
# pointer - pre-fix the release followed the forged field onto the
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
          (string "table closer over forged self - free unredirectable, graph block untouched: rc " rc ": " msg)))

# op-registry injection - pre-fix a single (put (get g :ops)
# <ptr> true) admitted a forged op past check-op; the
# registry now lives module-side (graph-state) and the public :ops
# field is gone: the pre-fix injection shape puts an INERT field and
# the forged op still raises the provenance class.
(def v4-t (rayforce/table-from-columns @{:a @[1.0 2.0]}))
(def v4-g (rayforce/graph v4-t))
(assert (nil? (get v4-g :ops)) "the op registry is no longer a public handle field")
(put v4-g :ops @{(get v4-t :ptr) true})
(assert-raises (fn [] (rayforce/add v4-g {:graph v4-g :id (get v4-t :ptr)}
                                    {:graph v4-g :id (get v4-t :ptr)}))
               "op provenance check failed"
               "the pre-fix injection shape no longer admits a forged op")
(:close v4-g) (:close v4-t)

#==------------------------------------------------------------------------==#
# Guard regressions (optional-array guards and error-path cleanup):
# each shape observed pre-fix - a non-array sort
# descs/nulls-first reached the length match and leaked the raw core
# error ("expected string, symbol, keyword, array, tuple, table, struct
# or buffer, got true"); a mid-loop raise in table-from-columns
# stranded the accumulated engine table, net 192-320 bytes per failed
# call, error path only
#==------------------------------------------------------------------------==#

# the optional plan-array guard (the A8.4 pattern) - descs/nulls-first join the guarded plan-array family.
(def v6-t (rayforce/table-from-columns @{:a @[3.0 1.0 2.0]}))
(def v6-g (rayforce/graph v6-t))
(def v6-node (rayforce/const-table v6-g v6-t))
(assert-raises (fn [] (rayforce/sort v6-g v6-node
                                    [(rayforce/scan v6-g "a")] true))
               "rayforce: sort: descs must be a boolean array, got boolean"
               "sort non-array descs raises the module class")
(assert-raises (fn [] (rayforce/sort v6-g v6-node
                                    [(rayforce/scan v6-g "a")] [false] 5))
               "rayforce: sort: nulls-first must be a boolean array, got number"
               "sort non-array nulls-first raises the module class")
(:close v6-g) (:close v6-t)

# the add-col-loop error-path cleanup - pre-fix the deferred-type element fence mid-loop stranded
# the partially built engine table; the cleanup releases the wrapper's
# blocks before re-raising, so the raise path nets 0 (first-column and
# third-column failure lanes).
(net0 (fn []
  (try (rayforce/table-from-columns @{:a @["x"]}) ([e] e)))
  "first-column element failure nets 0")
(net0 (fn []
  (try (rayforce/table-from-columns
        @{:a @[1.0 2.0] :b @[3.0 4.0] :c @["x" "y"]}) ([e] e)))
  "third-column element failure nets 0")

(print "rayforce smoke ok")
