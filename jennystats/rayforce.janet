# jennystats/rayforce.janet - typed-contract Janet binding over the Rayforce
# columnar engine, via core ffi (not a native module).
#
# Public package: janet-rayforce. License: AGPLv3 (see LICENSE). The
# bound engine is MIT (its notice ships with the upstream source the
# installer pins; the engine ships whole in this binary - see the
# embedding statement).
# Repo: janet-rayforce; the behavioural spec is
# specs/api-contract.md in this repository.
#
# Embedding statement (contract section 8, from birth): this module
# embeds the FULL Rayforce engine - the Rayfall string evaluator is in
# the binary and cannot be removed by build or link choices - but it is
# never exposed: no public function evaluates a string, the parquet
# reader never reaches it, only caller-constructed plan nodes feed the
# expression path.
#
# Platform (contract section 10): Linux x86_64 built and tested;
# macOS compile-plausible, unverified; Windows route is WSL2.
#
# Pinned C ABI: RayforceDB/rayforce v2.11.5 (tarball sha256 in
# libs/install-rayforce.sh, which also cross-checks the four
# vendored headers before every build). This is a raw plan-plane
# binding - no convenience wrappers (the janet-rayql boundary);
# no rayql features.
#
# Lib resolution: $RAYFORCE_LIB -> ~/.local/lib/rayforce/librayforce.so
# -> dlopen search. Import fails actionably if none loads.
#
# Public API (behavioural spec: the api-contract):
#   (engine-version)                    -> [major minor patch]
#   (table-from-columns cols &opt names) -> table handle
#   (table-nrows tbl) / (table-ncols tbl) -> int
#   (table-column tbl name)             -> array of values | nil
#   (table-columns tbl)                 -> struct name -> array
#   (graph tbl)                         -> graph handle
#   (add-table g tbl)                   -> table id (scan-table source)
#   (scan g name) / (scan-table g tid name) -> op
#   (const-table g tbl)                 -> op (a table node)
#   (const-f64 g v) / (const-i64 g v) / (const-bool g v) -> op
#   (add g a b) .. arithmetic/comparison/logic ops, (if g c t e) -> op
#   (filter g input pred) (select g input cols) (sort g input keys ...)
#   (group g keys aggs) (distinct g keys) (join g left lkeys right rkeys ...)
#   (head g input n) / (tail g input n) -> op
#   (optimize g root) -> op  (execute g root) -> table handle
#   (parquet-rows path &opt batch)      -> array of table handles
# Handles: table/graph are tables with :kind :ptr and an idempotent
# :close; `with` works. Handle provenance is verified (contract
# addendum A9/A10): tables by the engine's own type tag, graphs by
# live-pointer registry identity plus module-side graph-state (ops,
# added tables, bound pointer - keyed by the graph pointer). Ops are
# NOT handles (graph-scoped borrows, {:graph :id}). The guards catch
# programming errors at the API surface (wrong-kind handles, use-
# after-close, cross-graph confusion, malformed plans - every such
# path raises); they are not a sandbox - in-process code can reach
# the module's state via the module environment and the engine ffi
# directly, and the module does not defend against that caller
# (contract addendum A11). Nulls: unified nil<->NaN both directions
# (addendum A2); i64/f64 only at ingest, STR/SYM raise deferred.

(import jennystats/typed :prefix "")

(put (curenv) :doc
     "Typed-contract Janet binding over the Rayforce columnar engine
  (core ffi, not a native module). Raw plan-plane surface - the
  compositional layer belongs to janet-rayql. EMBEDDING STATEMENT:
  this module embeds the FULL Rayforce engine - the Rayfall string
  evaluator is present in the binary (the DAG executor evaluates its
  expression arguments through it; it cannot be removed by build or
  link choices) and is NEVER EXPOSED: no public function evaluates a
  string, the parquet reader never reaches it, only caller-constructed
  plan nodes feed the expression path (enforced by the smoke
  suite). Platform: Linux x86_64 built and tested; macOS
  compile-plausible, unverified; Windows route WSL2.")

#==------------------------------------------------------------------------==#
# Lib resolution (probe BEFORE the ffi context - the duckdb D1 lesson)
#==------------------------------------------------------------------------==#

(defn/typed lib-path {:args [] :ret :string} []
  "Resolve librayforce.so: $RAYFORCE_LIB, then the pinned home path,
  then the bare soname for the system dlopen search."
  (def env (get (os/environ) "RAYFORCE_LIB"))
  (if env env
    (let [home (get (os/environ) "HOME")
          pinned (string home "/.local/lib/rayforce/librayforce.so")]
      (if (not (nil? (os/stat pinned))) pinned "librayforce.so"))))

(def lib (lib-path))

(unless (try (do (ffi/native lib) true) ([_] false))
  (errorf "rayforce: cannot load %s - run libs/install-rayforce.sh or set $RAYFORCE_LIB" lib))

(ffi/context lib)

#==------------------------------------------------------------------------==#
# Bindings - header-cited (source lines in comments)
#==------------------------------------------------------------------------==#

# Lifecycle (rayforce.h:63-65, 220, 468-469, 650)
(ffi/defbind ray_version_major :int [])
(ffi/defbind ray_version_minor :int [])
(ffi/defbind ray_version_patch :int [])
(ffi/defbind ray_heap_init :void [])
(ffi/defbind ray_sym_init :int [])
(ffi/defbind ray_retain :void [v :ptr])
(ffi/defbind ray_release :void [v :ptr])

# Error objects (rayforce.h:260-266). ray_error_msg is
# exported by the archive but undeclared in the public header (an
# upstream documentation gap); it is the message half of the
# contract's error text - read via a char** cell, nil when unset.
(ffi/defbind ray_err_from_obj :int [err :ptr])
(ffi/defbind ray_err_code :string [err :ptr])
(ffi/defbind ray_error_msg :ptr [])
(ffi/defbind ray_error_free :void [err :ptr])

# Introspection + data plane (rayforce.h:337-341, 597-622,
# 626, 635, 711-721)
(ffi/defbind ray_obj_type :int [v :ptr])
(ffi/defbind ray_vec_get_i64 :int64 [vec :ptr idx :int64])
(ffi/defbind ray_vec_get_f64 :double [vec :ptr idx :int64])
(ffi/defbind ray_vec_get :ptr [vec :ptr idx :int64])
(ffi/defbind ray_str_ptr :string [s :ptr])
(ffi/defbind ray_vec_new :ptr [type :int8 capacity :int64])
(ffi/defbind ray_vec_from_raw :ptr [type :int8 data :ptr count :int64])
(ffi/defbind ray_vec_append_raw :ptr [vec :ptr src :ptr count :int64])
(ffi/defbind ray_vec_set_null :void [vec :ptr idx :int64 is-null :bool])
(ffi/defbind ray_vec_is_null :bool [vec :ptr idx :int64])
(ffi/defbind ray_table_new :ptr [ncols :int64])
(ffi/defbind ray_table_add_col :ptr [tbl :ptr name-id :int64 col-vec :ptr])
(ffi/defbind ray_table_validate_rectangular :ptr [tbl :ptr context :string])
(ffi/defbind ray_table_get_col :ptr [tbl :ptr name-id :int64])
(ffi/defbind ray_table_get_col_idx :ptr [tbl :ptr idx :int64])
(ffi/defbind ray_table_col_name :int64 [tbl :ptr idx :int64])
(ffi/defbind ray_table_ncols :int64 [tbl :ptr])
(ffi/defbind ray_table_nrows :int64 [tbl :ptr])
(ffi/defbind ray_sym_intern :int64 [str :string len :uint64])
(ffi/defbind ray_sym_find :int64 [str :string len :uint64])
(ffi/defbind ray_sym_str :ptr [id :int64])

# Plan plane (ops.h:699-756, 813-861, 928, 961)
(ffi/defbind ray_graph_new :ptr [tbl :ptr])
(ffi/defbind ray_graph_free :void [g :ptr])
(ffi/defbind ray_graph_add_table :uint16 [g :ptr tbl :ptr])
(ffi/defbind ray_scan :ptr [g :ptr col :string])
(ffi/defbind ray_scan_table :ptr [g :ptr tid :uint16 col :string])
(ffi/defbind ray_const_f64 :ptr [g :ptr val :double])
(ffi/defbind ray_const_i64 :ptr [g :ptr val :int64])
(ffi/defbind ray_const_bool :ptr [g :ptr val :bool])
(ffi/defbind ray_const_table :ptr [g :ptr tbl :ptr])
(ffi/defbind ray_neg :ptr [g :ptr a :ptr])
(ffi/defbind ray_not :ptr [g :ptr a :ptr])
(ffi/defbind ray_isnull :ptr [g :ptr a :ptr])
(ffi/defbind ray_add :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_sub :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_mul :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_div :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_mod :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_idiv :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_eq :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_ne :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_lt :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_le :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_gt :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_ge :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_and :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_or :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_if :ptr [g :ptr c :ptr t :ptr e :ptr])
(ffi/defbind ray_min2 :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_max2 :ptr [g :ptr a :ptr b :ptr])
(ffi/defbind ray_filter :ptr [g :ptr input :ptr pred :ptr])
(ffi/defbind ray_select_op :ptr [g :ptr input :ptr cols :ptr n :uint32])
(ffi/defbind ray_sort_op :ptr [g :ptr table-node :ptr keys :ptr descs :ptr nulls-first :ptr n :uint32])
(ffi/defbind ray_group :ptr [g :ptr keys :ptr n-keys :uint32 agg-ops :ptr agg-ins :ptr n-aggs :uint32])
(ffi/defbind ray_distinct :ptr [g :ptr keys :ptr n :uint32])
(ffi/defbind ray_join :ptr [g :ptr left :ptr lkeys :ptr right :ptr rkeys :ptr n :uint32 jtype :uint8])
(ffi/defbind ray_head :ptr [g :ptr input :ptr n :int64])
(ffi/defbind ray_tail :ptr [g :ptr input :ptr n :int64])
(ffi/defbind ray_optimize :ptr [g :ptr root :ptr])
(ffi/defbind ray_execute :ptr [g :ptr root :ptr])

# Parquet read (parquet.h:14-28)
(ffi/defbind ray_parquet_open :ptr [path :string columns :ptr batch :int64 out :ptr])
(ffi/defbind ray_parquet_next :ptr [reader :ptr])
(ffi/defbind ray_parquet_close :void [reader :ptr])
(ffi/defbind ray_parquet_metadata :ptr [path :string])

# Memory trace (heap.h:246-248) - the smoke's
# leak-counting tier, not public surface.
(ffi/defbind ray_mem_trace_begin :bool [])
(ffi/defbind ray_mem_trace_end :void [out :ptr])
(ffi/defbind ray_mem_stats :void [out :ptr])

# ray_eval_str is deliberately NOT bound (the embedding statement's
# enforcement - the smoke suite asserts its absence from this module).

# Engine type tags (rayforce.h:74-102) and the trace struct (heap.h:166-173)
(def RAY-I64 5)
(def RAY-F64 7)
(def RAY-SYM 12)
(def RAY-STR 13)
(def RAY-ERROR 127)
(def RAY-TABLE 98)
(def RAY-BOOL 1)
(def trace-struct (ffi/struct :uint64 :uint64 :uint64 :uint64 :int64 :uint64))
(def TAG-NAMES {1 "BOOL" 2 "U8" 3 "I16" 4 "I32" 5 "I64" 6 "F32" 7 "F64"
                8 "DATE" 9 "TIME" 10 "TIMESTAMP" 11 "GUID" 12 "SYM" 13 "STR"})

# Init once per process (both idempotent; policy init-once)
(ray_heap_init)
(def sym-init-rc (ray_sym_init))
(unless (zero? sym-init-rc)
  (errorf "rayforce: sym init failed: %d" sym-init-rc))

#==------------------------------------------------------------------------==#
# Error rule (implemented once) + type guards
#==------------------------------------------------------------------------==#

(defn/typed c-string {:args [:any] :ret :string} [char-ptr]
  "Read a char* handed back by the engine as a janet string; ffi/read
  :string expects a pointer cell (the duckdb deref pattern)."
  (ffi/read :string (ffi/write :ptr char-ptr)))

(defn/typed err! {:args [:any :string] :ret :any} [p what]
  "THE error-object rule (contract section 3), implemented once for
  every error-returning engine call: a ray_t* whose RAY_IS_ERR marker
  is set (the type tag reads RAY_ERROR - the header's from_obj
  parenthetical is wrong, it maps codes and returns RAY_ERR_DOMAIN
  for every NON-error) gets its ASCII code
  extracted, the engine's message read, the object freed with
  ray_error_free (the generic release is a deliberate no-op on error
  objects), and a janet error raised. A clean value
  passes through; callers never see a raw engine error object."
  (when (and p (= RAY-ERROR (ray_obj_type p)))
    (def code (try (ray_err_code p) ([_] "?")))
    (def msg-ptr (ray_error_msg))
    (def msg (if (nil? msg-ptr) nil (c-string msg-ptr)))
    (ray_error_free p)
    (errorf "rayforce: %s failed: %s" what
            (if (or (nil? msg) (empty? msg)) code (string code ": " msg))))
  p)

(defn/typed check-table {:args [:any] :ret :any} [x]
  "Type-guard class (contract section 3): every table-taking fn raises
  on a wrong-kind, closed or non-handle argument before any engine
  call. Provenance (addendum A8): beyond
  kind+pointer-ness, the pointer must be an ENGINE table block -
  ray_obj_type reads the block's type tag (byte 18 of the 32-byte
  ray_t header, rayforce.h:190-227), so a graph pointer (or any
  other object) under a :table kind raises here instead of reading
  silent garbage from the engine (observed pre-fix: table-nrows
  returned 0 over a graph pointer)."
  (unless (and (or (struct? x) (table? x))
               (= :pointer (type (get x :ptr)))
               (= :table (get x :kind)))
    (errorf "rayforce: expected table handle, got %s" (type x)))
  (when (get x :closed)
    (error "rayforce: table already closed"))
  (unless (= RAY-TABLE (ray_obj_type (get x :ptr)))
    (error "rayforce: table handle provenance check failed - the pointer is not an engine table block (a forged or cross-kind handle never reaches the engine)"))
  x)

# Graph provenance (addendum A9):
# the ABI affords no graph introspection (no tag, no registry query -
# ops.h:508-533). The original provenance token was a plain
# readable field, so a
# forged handle with the copied token reached the engine (exit 139
# over a table pointer, silent garbage over a freed one). The
# registry now maps every LIVE graph pointer to its handle and
# check-graph resolves the handle through registry IDENTITY - a fact
# no field copy can reproduce (a forged or swapped handle is a
# different value). Cleared on :close. The token stays as a second
# fence.
#
# A10 shape decision: the fence
# state itself moved MODULE-SIDE - graph-state (ops registry, added-
# table registry, bound pointer) is keyed by the graph pointer, so no
# public handle field is load-bearing for any check (a field put can
# no longer inject an op id or redirect a validation source). Struct
# handles (the contract's original section-6 wording) were evaluated
# and REJECTED: janet structs compare by content, so a field-for-field
# copy of a genuine handle would be = to the registered handle and
# pass the identity fence - mutable-table identity is the one
# unforgeable fact, and the handles stay tables to keep it.
#
# A11 boundary: graph-registry/graph-state
# are top-level defs, hence exported in the module environment -
# in-process code CAN reach and mutate them through module/cache, so
# the state is not private against that caller; the guards bind misuse
# at the API surface, and hostile in-process code is out of scope
# (contract addendum A11).
(def graph-provenance (gensym))
(def graph-registry @{})
(def graph-state @{})

(defn/typed check-graph {:args [:any] :ret :any} [x]
  "Type-guard class: every graph/op-taking fn raises on a wrong-kind,
  closed or non-handle argument (the close-then-use UB fence).
  Provenance (addendum A9): the handle must BE the registered
  handle for its pointer - the original provenance token was a
  plain readable field, and a forged :kind :graph struct with the
  copied token over a table pointer reached ray_scan and
  SEGFAULTED (exit 139, observed pre-fix in a subprocess); over a
  FREED pointer it ran to completion with silent garbage (UAF). No
  ABI fact distinguishes a graph block, so registry identity is the
  fence: no fact used here is copyable off a genuine handle. Boundary
  (addendum A11): the registry itself is
  module-level and exported in the module environment, so in-process
  code can forge entries through module/cache - this fence binds API
  misuse, not that caller (contract A11)."
  (unless (and (or (struct? x) (table? x))
               (= :pointer (type (get x :ptr)))
               (= :graph (get x :kind)))
    (errorf "rayforce: expected graph handle, got %s" (type x)))
  (when (get x :closed)
    (error "rayforce: graph already closed"))
  (unless (= graph-provenance (get x :prov))
    (error "rayforce: graph handle provenance check failed - the handle was not constructed by this module (a forged or cross-kind handle never reaches the engine)"))
  (def reg (get graph-registry (get x :ptr)))
  (unless (and (not (nil? reg)) (= reg x))
    (error "rayforce: graph handle provenance check failed - the handle is not the registered live graph for its pointer (a forged, closed or swapped handle never reaches the engine)"))
  x)

(defn/typed check-op {:args [:any :any] :ret :any} [x g]
  "Type-guard class for op arguments: an op is a graph-scoped borrow
  {:graph :id} - the op's :graph must be the SAME graph as the call's
  (wrong-graph reuse raises, never crosses pointers).
  With check-graph's registry identity, identity to the call's g also
  proves the op's :graph is a genuine module-constructed handle; the
  op's :id must be a constructor-registered op of that graph
  (addendum A9 - the A8.1 shape-only boundary is superseded)."
  (check-graph g)
  (unless (and (or (struct? x) (table? x))
               (= :pointer (type (get x :id)))
               (= g (get x :graph)))
    (errorf "rayforce: expected op of this graph, got %s" (type x)))
  # op-id registry (addendum A9): shape-only let a foreign block
  # under a genuine graph reach the engine's op paths (silently
  # wrong values observed) - the op id must be a constructor-
  # registered op of THIS graph. A10: the registry is MODULE-SIDE
  # (graph-state), so a
  # field put on the public handle can no longer inject membership -
  # a caller mutating g's fields changes nothing any check reads.
  (def st (get graph-state (get g :ptr)))
  (unless (and (not (nil? st)) (get (get st :ops) (get x :id)))
    (error "rayforce: op provenance check failed - the op id is not a registered op of this graph (a forged op never reaches the engine)"))
  x)

#==------------------------------------------------------------------------==#
# Handle constructors (idempotent :close - contract section 6)
#==------------------------------------------------------------------------==#

(defn/typed make-table {:args [:any] :ret :table} [ptr]
  "A table handle: raw pointer, :kind :table, idempotent :close
  (ray_release - tables are refcounted values). Destructor provenance
  (addendum A10.1): the closure frees the pointer
  CAPTURED AT CONSTRUCTION and the idempotence flag lives on the
  genuine handle captured in the closure scope - the argument is
  ignored entirely, so a forged or mutated self cannot redirect the
  free or force a double release (the argument remains for the
  with/:close protocol shape)."
  (def t @{:ptr ptr :kind :table :closed false})
  (put t :close (fn [self] (unless (get t :closed)
                             (ray_release ptr)
                             (put t :closed true))
                   nil))
  t)

(defn/typed make-graph {:args [:any :any] :ret :table} [ptr tbl-ptr]
  "A graph handle: raw pointer, :kind :graph, idempotent :close
  (ray_graph_free - frees the DAG; the bound table survives).
  Carries the provenance token (check-graph, addendum A9) and
  NOTHING load-bearing: the op registry, the added-table registry
  and the bound pointer live module-side in graph-state (A10.2, the
  scan column validation source of addendum A8.2). Boundary
  (addendum A11): graph-state is module-level and
  exported in the module environment, so in-process code can reach
  and mutate it through module/cache - the guards bind API misuse,
  not that caller (contract A11). Destructor provenance (A10.1):
  the closure frees the pointer CAPTURED AT
  CONSTRUCTION and only while THIS handle is still the registered
  live graph - a forged or mutated self cannot redirect the free, a
  second call (any argument shape) is a no-op, and a stale closer
  cannot re-free a pointer the allocator has since handed to a new
  graph (the registry entry would name a different handle)."
  (def g @{:ptr ptr :kind :graph :closed false :prov graph-provenance})
  (put g :close (fn [self]
                  (when (= (get graph-registry ptr) g)
                    (ray_graph_free ptr)
                    (put graph-registry ptr nil)
                    (put graph-state ptr nil)
                    (put g :closed true))
                  nil))
  (put graph-state ptr @{:ops @{} :tables @[] :bound tbl-ptr})
  (put graph-registry ptr g)
  g)

(defn/typed make-op {:args [:any :any] :ret :struct} [g ptr]
  "An op: NOT a handle (contract section 6) - a graph-scoped borrow.
  Use after its graph closed is UB, fenced wrapper-side by check-op's
  graph-closed check."
  {:graph g :id ptr})

(defn/typed -ok-op {:args [:any :any :string] :ret :any} [ptr g what]
  "Guard for op constructors: the engine returns NULL only on
  allocation failure - raise rather than thread a null op through the
  DAG (the error-object check does NOT apply: ray_op_t* is not a
  ray_t*; RAY_IS_ERR would misread it)."
  (check-graph g)
  (unless (not (nil? ptr))
    (errorf "rayforce: %s failed: engine returned NULL" what))
  (def o (make-op g ptr))
  (put (get (get graph-state (get g :ptr)) :ops) ptr true)
  o)

#==------------------------------------------------------------------------==#
# Public API
#==------------------------------------------------------------------------==#

(defn/typed engine-version {:args [] :ret :tuple} []
  "The linked engine version as [major minor patch] (the smoke pins
  [2 11 5] on the installer's build)."
  [(ray_version_major) (ray_version_minor) (ray_version_patch)])

#==------------------------------------------------------------------------==#
# Data plane (contract sections 1, 4, 5)
#==------------------------------------------------------------------------==#

(defn/typed -check-elements {:args [:any :string] :ret :nil} [col what]
  "Deferred-type fence (contract section 5): a column may hold only
  numbers and nil - a string or symbol element raises the deferred
  class loud, never a coercion or a shortened table."
  (each v col
    (unless (or (number? v) (nil? v))
      (cond
        (or (string? v) (buffer? v))
        (errorf "rayforce: %s: unsupported column type: STR - deferred" what)
        (or (symbol? v) (keyword? v))
        (errorf "rayforce: %s: unsupported column type: SYM - deferred" what)
        (errorf "rayforce: %s: expected number or nil, got %s" what (type v))))))

(defn/typed -vec-from-column {:args [:any :string] :ret :any} [col what]
  "One engine F64 vector from a Janet column (the R c() rule: number
  arrays are ALWAYS F64 - typed integer storage arrives from parquet
  and execute results, never from inference). Null mapping is unified
  (contract addendum v1.0.1): a Janet nil sets the NULL_F64 sentinel
  via ray_vec_set_null; a NaN value passes through its own bits - and
  the engine reads any NaN as a null (x != x, upstream's deliberate
  design), so nil and NaN are the same encoding in both directions,
  the R is.na semantics."
  (-check-elements col what)
  (def n (length col))
  (def payload (seq [v :in col] (if (nil? v) 0.0 v)))
  (def buf (buffer/new-filled (* 8 n) 0))
  (when (pos? n) (ffi/write @[:double n] payload buf 0))
  (def vec (err! (ray_vec_from_raw RAY-F64 buf n) what))
  (eachp [i v] col
    (when (nil? v) (ray_vec_set_null vec i true)))
  vec)

(defn/typed decode-column {:args [:any :number :string] :ret :array} [col n what]
  "Read-back decode (contract section 4 + addendum v1.0.1): the null
  discriminator is ray_vec_is_null - for F64 that is any-NaN (the
  unified nil<->NaN mapping, R is.na semantics; no separate bitmap
  exists in the engine); i64 reads the native int64 lane with the
  NULL_I64 exact-sentinel decode (a stored NULL_I64 is a null, not
  INT64_MIN). STR/SYM raise the deferred class."
  (def tag (ray_obj_type col))
  (case tag
    RAY-I64 (seq [i :range [0 n]]
                (if (ray_vec_is_null col i) nil
                  (try (int/to-number (ray_vec_get_i64 col i))
                    ([e] (errorf "rayforce: %s: value outside the double-safe band [-2^53, 2^53] - the janet number model cannot represent it exactly" what)))))
    RAY-F64 (seq [i :range [0 n]]
                (if (ray_vec_is_null col i) nil (ray_vec_get_f64 col i)))
    RAY-BOOL (seq [i :range [0 n]]
                (if (ray_vec_is_null col i) nil
                  (not (zero? (ffi/read :uint8 (ray_vec_get col i))))))
    RAY-STR (errorf "rayforce: %s: unsupported column type: STR - deferred" what)
    RAY-SYM (errorf "rayforce: %s: unsupported column type: SYM - deferred" what)
    (errorf "rayforce: %s: unsupported column type: %s - deferred" what
            (or (get TAG-NAMES tag) (string tag)))))

(defn/typed -check-packed {:args [:any] :ret :nil} [packed]
  "The packed-seam guard (contract addendum A7.6): a packed f32
  handle is SHAPE-validated - :ptr a buffer or true pointer,
  :nrow/:ncol numbers, the pack's :n/:bytes accounting consistent,
  and the buffer form long enough for the claimed bytes (its reads
  are bounds-checked by ffi/read - no memory unsafety). It is NOT
  provenance-verified: a forged but consistently-shaped struct is
  indistinguishable from a janet-num pack by shape alone and builds
  whatever its bytes say - deeper validation is the caller's (the
  contract addendum A7 states this boundary)."
  (unless (and (or (struct? packed) (table? packed))
               (or (buffer? (get packed :ptr))
                   (= :pointer (type (get packed :ptr)))))
    (errorf "rayforce: expected packed f32 handle {:ptr :n :nrow :ncol}, got %s"
            (type packed)))
  (def nrow (get packed :nrow))
  (def ncol (get packed :ncol))
  (def n (get packed :n))
  (def bytes (get packed :bytes))
  (unless (and (number? nrow) (number? ncol) (number? n) (number? bytes)
               (pos? nrow) (pos? ncol) (>= bytes 0)
               (= n (* nrow ncol)) (= bytes (* 4 nrow ncol)))
    (errorf "rayforce: packed f32 handle shape mismatch (nrow %q ncol %q n %q bytes %q - expected positive shape, a janet-num pack-columns-f32 handle)"
            nrow ncol n bytes))
  (when (buffer? (get packed :ptr))
    # the buffer form is bounds-checked by ffi/read, but a short buffer
    # under a consistent shape reached it as a RAW janet error - check
    # the claimed byte count up front
    (unless (>= (length (get packed :ptr)) bytes)
      (errorf "rayforce: packed f32 handle buffer is %d bytes, claims %d"
              (length (get packed :ptr)) bytes))))

(defn/typed -packed-columns {:args [:any] :ret :array} [packed]
  "The janet-num f32 seam (contract section 4 + addendum v1.0.1): a
  packed handle's f32 rows widen to f64 columns (ffi :float reads
  widen exactly). The pack path encodes NULL as NaN - and since any
  NaN IS a null in the engine's F64 model, a pack-side null arrives
  as a null: the seam is symmetric with plain nil input (the planned
  asymmetry note is superseded)."
  (-check-packed packed)
  (def buf (packed :ptr))
  (def nrow (packed :nrow))
  (def ncol (packed :ncol))
  (def flat (if (pos? (* nrow ncol)) (ffi/read @[:float (* nrow ncol)] buf) []))
  (seq [c :range [0 ncol]]
    (seq [r :range [0 nrow]] (flat (+ (* r ncol) c)))))

(defn table-from-columns
  "A table handle from columns: an array of column arrays (numbers and
  nil; F64 storage always - the R c() rule), a struct of name ->
  array (names from the keys), or a janet-num packed f32 handle
  (:nrow :ncol; widened, pack-nulls arrive as NaN values). Optional
  names (equal-length array of strings) name array/packed input;
  struct input is named by its keys. All columns must be equal
  length - ragged input raises, never reaches the engine (it accepts
  ragged adds silently)."
  [cols &opt names]
  (default names nil)
  (def pairs
    (cond
      (and (or (struct? cols) (table? cols))
           (not (nil? (get cols :ptr)))
           (not (nil? (get cols :nrow)))
           (not (nil? (get cols :ncol))))
      (do # the packed f32 seam
        (when names (error "rayforce: a names argument is not accepted alongside packed input"))
        (def cols (-packed-columns cols))
        (map (fn [i col] [(string "col" i) col]) (range (length cols)) cols))
      (or (struct? cols) (table? cols))
      (do
        (when names (error "rayforce: names argument alongside struct input - the keys are the names"))
        # packed-like pre-check (addendum A9.6): a
        # map with :ptr but missing :nrow/:ncol previously fell
        # through to this struct branch with a misdirecting
        # container message.
        (each k [:nrow :ncol]
          (when (and (not (nil? (get cols :ptr))) (nil? (get cols k)))
            (errorf "rayforce: table-from-columns: packed-like input has :ptr but is missing :%s - the packed handle requires :ptr, :nrow and :ncol" (string k))))
        # the container fence (addendum A7.7): a struct VALUE
        # that is not a column array iterates as bytes/values and builds
        # silent garbage columns (observed pre-fix: "abc" -> @[97 98 99]) -
        # validate the container kind, exactly like array-input elements.
        (each [k v] (pairs cols)
          (unless (or (array? v) (tuple? v))
            (errorf "rayforce: table-from-columns: struct value for column %s must be a column array, got %s"
                    (string k) (type v))))
        (seq [p :in (pairs cols)] [(string (first p)) (last p)]))
      (or (array? cols) (tuple? cols))
      (do
        # the names-length guard, BEFORE any pair building (addendum
        # A7.1): a names array shorter than cols made map stop at the
        # shorter side - columns silently DROPPED, exit 0 (observed pre-fix:
        # 2 columns + ["a"] -> a 1-column table). The old post-map guard
        # was unreachable (pairs already truncated). Names must match the
        # column count exactly and be strings.
        (each c cols
          (unless (or (array? c) (tuple? c))
            (errorf "rayforce: table-from-columns: columns must be arrays, got %s" (type c))))
        (when names
          (unless (and (or (array? names) (tuple? names))
                       (= (length names) (length cols)))
            (if (or (array? names) (tuple? names))
              (errorf "rayforce: table-from-columns: names length (%d) does not match column count (%d)"
                      (length names) (length cols))
              (errorf "rayforce: table-from-columns: names must be an array of %d strings, got %s"
                      (length cols) (type names))))
          (each nm names
            (unless (string? nm)
              (errorf "rayforce: table-from-columns: names must be strings, got %s" (type nm))))
          # the duplicate-names fence (addendum A8.5): the engine
          # accepts duplicate add_col names, but its two read paths
          # then disagree (table-column resolves the FIRST, table-columns
          # keeps the LAST - observed pre-fix) - a silent divergence at the
          # naming boundary; the typed-contract model requires unique
          # names (R tolerates duplicates; this stack does not).
          (def seen @{})
          (each nm names
            (when (get seen nm)
              (errorf "rayforce: table-from-columns: duplicate column name %q - table-column resolves the first and table-columns keeps the last; names must be unique" nm))
            (put seen nm true)))
        (def ns (or names (seq [i :range [0 (length cols)]] (string "col" i))))
        (map (fn [nm col] [(string nm) col]) ns cols))
      (or (buffer? cols) (bytes? cols))
      (error "rayforce: expected packed f32 handle {:ptr :n :nrow :ncol}, got buffer - the seam takes a janet-num pack handle, not a raw buffer")
      (errorf "rayforce: table-from-columns: expected columns, packed handle or struct, got %s" (type cols))))
  # the R4 guard: equal length Janet-side (the engine accepts ragged
  # adds silently - observed pre-fix: [[3-row],[2-row]] built a 3-row table
  # with a phantom 0 value); validate_rectangular is the engine-side
  # belt behind it.
  (when (empty? pairs) (error "rayforce: table-from-columns: no columns"))
  (def nrow (length (get (first pairs) 1)))
  (each [name col] pairs
    (unless (= nrow (length col))
      (errorf "rayforce: ragged columns (column %s: %d rows, expected %d)"
              name (length col) nrow)))
  # add-col loop: the consuming call (contract section 2, the one
  # consuming row): the wrapper keeps NO ref across adds - it
  # continues from each return; on error the engine consumed the ref
  # and the wrapper drops the cell (raises, never releases the stale
  # handle - a release there would be the double-free counterfactual).
  (var t (err! (ray_table_new (length pairs)) "table new"))
  # error-path cleanup (addendum A12.9): a raise inside
  # the loop previously stranded the accumulated engine table; the
  # wrapper releases exactly what it still owns before re-raising -
  # the pending column vec (the engine retains the caller's column
  # ref per section 2, so it is ours on every path), and the table
  # ONLY when the raise is not the consuming add-col call (a failed
  # add_col consumes the table ref, contract section 2).
  (var pending nil)
  (var t-consumed false)
  (try
    (do
      (each [name col] pairs
        (def vec (-vec-from-column col (string "column " name)))
        (set pending vec)
        (def id (ray_sym_intern name (length name)))
        (set t-consumed true)
        (set t (err! (ray_table_add_col t id vec)
                     (string "add column " name)))
        (set t-consumed false)
        (set pending nil)
        (ray_release vec))
      (err! (ray_table_validate_rectangular t "table-from-columns") "validate rectangular")
      (make-table t))
    ([e] (when pending (ray_release pending))
         (unless t-consumed (ray_release t))
         (error e))))

(defn/typed table-nrows {:args [:any] :ret :number} [tbl]
  "Row count of a table handle."
  (check-table tbl)
  (int/to-number (ray_table_nrows (get tbl :ptr))))

(defn/typed table-ncols {:args [:any] :ret :number} [tbl]
  "Column count of a table handle."
  (check-table tbl)
  (int/to-number (ray_table_ncols (get tbl :ptr))))

(defn/typed -column-name {:args [:any :number] :ret :string} [tbl idx]
  "The interned name of column idx (sym id -> interned string atom,
  read through ray_str_ptr; the sym table retains these)."
  (def id (ray_table_col_name (get tbl :ptr) idx))
  (when (neg? id) (errorf "rayforce: column %d has no name" idx))
  (ray_str_ptr (ray_sym_str id)))

(defn/typed table-column {:args [:any :string] :ret :any} [tbl name]
  "The named column as a Janet array (decode per contract section 4),
  or nil when the table has no such column. get_col returns a
  BORROWED ref (source table.c:211-225 - the earlier owned-row reading
  misattributed the header's totality docs; releasing it corrupts the
  heap, observed as a phantom third column in the next build) -
  the copy-out releases nothing."
  (check-table tbl)
  (def id (ray_sym_find name (length name)))
  (when (neg? id) (break nil))
  (def col (ray_table_get_col (get tbl :ptr) id))
  (when (nil? col) (break nil))
  (decode-column col (int/to-number (ray_table_nrows (get tbl :ptr)))
                 (string "column " name)))

(defn/typed table-columns {:args [:any] :ret :struct} [tbl]
  "Every column as a struct name -> array (per-column ownership and
  decode as table-column)."
  (check-table tbl)
  (def ptr (get tbl :ptr))
  (def n (int/to-number (ray_table_ncols ptr)))
  (def rows (int/to-number (ray_table_nrows ptr)))
  (def kvs @[])
  (for i 0 n
    (def col (ray_table_get_col_idx ptr i))
    (when (nil? col) (errorf "rayforce: column %d missing" i))
    (array/push kvs (-column-name tbl i))
    (array/push kvs (decode-column col rows (string "column " i))))
  (struct ;kvs))

#==------------------------------------------------------------------------==#
# Plan plane (contract section 1 - the raw plan surface,
# no convenience wrappers, no rayql features)
#==------------------------------------------------------------------------==#

(def AGG-OPS {:sum 50 :avg 55 :min 52 :max 53 :count 54
              :count-distinct 58 :first 56 :last 57 :stddev 59 :var 74})
(def JOIN-TYPES {:inner 0 :left 1 :full 2 :anti 3})

(defn/typed -op-ids {:args [:any :any] :ret :any} [ops g]
  "The :id pointers of same-graph ops as a janet array (for the ffi
  ptr-array lanes); every op is checked against the call's graph."
  (seq [op :in ops] (get (check-op op g) :id)))

(defn/typed -check-scan-col {:args [:any :string :string] :ret :nil} [tbl-ptr name what]
  "The malformed-plan guard (addendum A8.2): the
  engine only marks an unknown-column scan OP_FLAG_INVALID_SCAN
  (ops.h:381) and just the filter/distinct executor surfaces it - a
  select projection silently yields an empty or narrowed table
  (observed pre-fix). The wrapper validates the column against the source
  table before the engine call, so a typo'd projection raises the
  validation class at scan time (contract section 3's totality)."
  (def id (ray_sym_find name (length name)))
  (when (or (neg? id) (nil? (ray_table_get_col tbl-ptr id)))
    (errorf "rayforce: %s: column %q not found in the source table" what name)))

(defn graph
  "A graph handle over a table (the table is borrowed - the engine
  retains it; graph :close frees the DAG and releases it - the bound
  table survives)."
  [tbl]
  (check-table tbl)
  (def g (ray_graph_new (get tbl :ptr)))
  (unless g (error "rayforce: graph failed: engine returned NULL"))
  (make-graph g (get tbl :ptr)))

(defn/typed add-table {:args [:any :any] :ret :number} [g tbl]
  "Add a second table to a graph; returns its table id - the only tid
  source for scan-table. The graph retains the table (released at
  graph close)."
  (check-graph g)
  (check-table tbl)
  (def tid (ray_graph_add_table (get g :ptr) (get tbl :ptr)))
  (when (= 65535 tid) (error "rayforce: add-table failed: engine returned error sentinel"))
  # track the registry module-side (A10.2 - a public mutable field was
  # injectable): sequential from 0, verified on
  # this pin (b->0, c->1) so scan-table can validate its column name
  (def ts (get (get graph-state (get g :ptr)) :tables))
  (unless (= tid (length ts))
    (error "rayforce: add-table failed: registry index out of sync"))
  (array/push ts (get tbl :ptr))
  tid)

(defn/typed scan {:args [:any :string] :ret :any} [g name]
  "A column op: the named column of the graph's bound table. The name
  is validated against the bound table (addendum A8.2) - the
  engine only flags unknown columns for the filter/distinct executor
  and a select projection would silently yield an empty/narrowed
  table. The bound-table rule is the surface semantic: a column of an
  ADDED table needs scan-table."
  (check-graph g)
  (-check-scan-col (get (get graph-state (get g :ptr)) :bound) name "scan")
  (-ok-op (ray_scan (get g :ptr) name) g "scan"))

(defn/typed scan-table {:args [:any :number :string] :ret :any} [g tid name]
  "A column op: the named column of an added table (tid from
  add-table). The name is validated against the registered table
  (addendum A8.2)."
  (check-graph g)
  (unless (and (>= tid 0) (<= tid 65534) (= tid (math/round tid)))
    (errorf "rayforce: scan-table: table id must be an integer in [0, 65534], got %q" tid))
  (def ts (get (get graph-state (get g :ptr)) :tables))
  (when (and (array? ts) (< tid (length ts)))
    (-check-scan-col (get ts tid) name "scan-table"))
  (-ok-op (ray_scan_table (get g :ptr) tid name) g "scan-table"))

(defn/typed const-table {:args [:any :any] :ret :any} [g tbl]
  "A table node op wrapping a table handle - the input op class for
  filter/select/sort/join/head/tail (the DAG's structural ops take
  table nodes, not column ops). The engine retains the table;
  graph close releases it."
  (check-graph g)
  (check-table tbl)
  (-ok-op (ray_const_table (get g :ptr) (get tbl :ptr)) g "const-table"))

(defn/typed const-f64 {:args [:any :number] :ret :any} [g v]
  "An f64 scalar constant op."
  (-ok-op (ray_const_f64 (get (check-graph g) :ptr) v) g "const-f64"))

(defn/typed const-i64 {:args [:any :any] :ret :any} [g v]
  "An i64 scalar constant op. The value must be an exact integer INSIDE
  the double-safe band [-2^53, 2^53] (addendum A8.3): beyond it the
  janet number model cannot represent the
  value exactly and the ffi conversion leaks a raw core error
  (observed pre-fix at 2^53+1 and 1e300) - enter out-of-band i64 values
  through the parquet/typed-source path. Argument typing is manual
  here (addendum A9.6): the defn/typed contract check raised
  without the module prefix."
  (unless (number? v)
    (errorf "rayforce: const-i64: expected a number, got %s" (type v)))
  (unless (= v (math/round v)) (errorf "rayforce: const-i64: %q is not an integer" v))
  (unless (and (>= v -9007199254740992) (<= v 9007199254740992))
    (errorf "rayforce: const-i64: %q is outside the double-safe band [-2^53, 2^53] - use the i64 parquet/typed-source path" v))
  (-ok-op (ray_const_i64 (get (check-graph g) :ptr) v) g "const-i64"))

(defn/typed const-bool {:args [:any :any] :ret :any} [g v]
  "A boolean scalar constant op (nil reads as false; any other
  non-boolean value raises the type-guard class - addendum A8.3: a
  string previously built a TRUE constant silently)."
  (unless (or (nil? v) (boolean? v))
    (errorf "rayforce: const-bool: expected a boolean or nil (nil reads as false), got %s" (type v)))
  (-ok-op (ray_const_bool (get (check-graph g) :ptr) (not (nil? v))) g "const-bool"))

(defmacro defexpr
  "Expression-op boilerplate: a graph + op args -> op constructor
  binding, every op checked against the call's graph."
  [name cfn & args]
  (def docstring (string "An expression op (" cfn ") - ops are graph-scoped
  borrows; every op argument must belong to the call's graph."))
  (def argchecks (map (fn [a] ~(get (check-op ,a g) :id)) args))
  ~(defn ,name ,docstring [g ,;args]
     (check-graph g)
     (-ok-op (,cfn (get g :ptr) ,;argchecks) g ,(string cfn))))

(defexpr add ray_add a b)
(defexpr sub ray_sub a b)
(defexpr mul ray_mul a b)
(defexpr div ray_div a b)
(defexpr mod ray_mod a b)
(defexpr idiv ray_idiv a b)
(defexpr eq ray_eq a b)
(defexpr ne ray_ne a b)
(defexpr lt ray_lt a b)
(defexpr le ray_le a b)
(defexpr gt ray_gt a b)
(defexpr ge ray_ge a b)
(defexpr min2 ray_min2 a b)
(defexpr max2 ray_max2 a b)
(defexpr neg ray_neg a)
(defexpr not ray_not a)
(defexpr isnull ray_isnull a)
(defexpr and2 ray_and a b)
(defexpr or2 ray_or a b)

(defn/typed if {:args [:any :any :any :any] :ret :any} [g c t e]
  "The conditional expression op: per-row branch between t and e by
  the boolean column c."
  (check-graph g)
  (def g-p (get g :ptr))
  (-ok-op (ray_if g-p (get (check-op c g) :id)
                  (get (check-op t g) :id) (get (check-op e g) :id))
          g "if"))

(defn/typed filter {:args [:any :any :any] :ret :any} [g input pred]
  "The filter structural op: rows of the table op `input` where the
  boolean expression `pred` holds."
  (check-graph g)
  (def g-p (get g :ptr))
  (-ok-op (ray_filter g-p (get (check-op input g) :id)
                      (get (check-op pred g) :id))
          g "filter"))

(defn/typed select {:args [:any :any :any] :ret :any} [g input cols]
  "The projection structural op: the table op `input` narrowed to the
  column ops `cols` (same-graph ops, order preserved). cols must be a
  NON-EMPTY array of ops (addendum A8.2): a nil,
  non-array or empty cols previously built a plan whose execution
  silently returned an empty table (the engine flags nothing on the
  projection path) - contract section 3's \"projecting nothing\"
  raises here."
  (check-graph g)
  (unless (and (or (array? cols) (tuple? cols)) (pos? (length cols)))
    (errorf "rayforce: select: cols must be a non-empty array of ops, got %s"
           (if (and (or (array? cols) (tuple? cols))) "an empty array" (type cols))))
  (def ids (-op-ids cols g))
  (-ok-op (ray_select_op (get g :ptr) (get (check-op input g) :id)
                        (ffi/write @[:ptr (length ids)] ids) (length ids))
          g "select"))

(defn sort
  "The sort structural op: the table op `input` ordered by the key
  ops `keys`. descs/nulls-first are per-key boolean arrays (defaults:
  ascending, nulls last)."
  [g input keys &opt descs nulls-first]
  (default descs nil)
  (default nulls-first nil)
  (check-graph g)
  (unless (or (array? keys) (tuple? keys))
    (errorf "rayforce: sort: keys must be an array of ops, got %s" (type keys)))
  (def n (length keys))
  (unless (pos? n) (error "rayforce: sort: no keys"))
  # optional plan-array guards (addendum A12.8): a
  # non-array descs/nulls-first previously reached the length match
  # below and leaked a raw core error; they join the A8.4 family.
  (when descs
    (unless (or (array? descs) (tuple? descs))
      (errorf "rayforce: sort: descs must be a boolean array, got %s" (type descs))))
  (when nulls-first
    (unless (or (array? nulls-first) (tuple? nulls-first))
      (errorf "rayforce: sort: nulls-first must be a boolean array, got %s" (type nulls-first))))
  (def d (or descs (seq [_ :range [0 n]] false)))
  (def nf (or nulls-first (seq [_ :range [0 n]] false)))
  (unless (and (= n (length d)) (= n (length nf)))
    (errorf "rayforce: sort: descs/nulls-first must match the key count (%d)" n))
  # per-element boolean fence (addendum A9.6):
  # non-boolean elements were coerced through truthiness; the
  # const-bool precedent rejects them.
  (each [arr what] [[d "descs"] [nf "nulls-first"]]
    (each el arr
      (unless (boolean? el)
        (errorf "rayforce: sort: %s must be a boolean array, got a %s element" what (type el)))))
  (-ok-op (ray_sort_op (get g :ptr) (get (check-op input g) :id)
                       (ffi/write @[:ptr n] (-op-ids keys g))
                       (ffi/write @[:uint8 n] (map |(if $ 1 0) d))
                       (ffi/write @[:uint8 n] (map |(if $ 1 0) nf))
                       n)
          g "sort"))

(defn/typed -op-out-type {:args [:any] :ret :any} [op]
  "The inferred output type of an op (ray_op_t.out_type, ops.h:391 -
  populated at construction: 7 F64, 5 I64, 1 BOOL, 98 TABLE). The
  join-key fence's evidence source (addendum A7.2): the
  engine compares join keys by RAW PAYLOAD, so mixed key types
  silently drop non-zero matches (observed pre-fix: only 0 matched); the
  row-wise expression path coerces correctly."
  (get (ffi/read (ffi/struct :uint16 :uint8 :uint8 :int8) (get op :id)) 3))

(defn/typed group {:args [:any :any :any] :ret :any} [g group-keys aggs]
  "The group-by structural op: group-keys is an array of same-graph
  column ops; aggs is an array of [input-op agg-keyword] pairs (the
  v1 agg set: :sum :avg :min :max :count :count-distinct :first
  :last :stddev :var). (The parameter is named group-keys: a `keys`
  param shadowed the core fn and leaked a raw janet error from the
  unknown-agg guard - addendum A7.8.)"
  (check-graph g)
  (unless (or (array? group-keys) (tuple? group-keys))
    (errorf "rayforce: group: keys must be an array of ops, got %s" (type group-keys)))
  (unless (pos? (length group-keys)) (error "rayforce: group: no keys"))
  (unless (or (array? aggs) (tuple? aggs))
    (errorf "rayforce: group: aggs must be an array of [input-op agg-keyword] pairs, got %s" (type aggs)))
  (each pair aggs
    (unless (and (or (tuple? pair) (array? pair)) (= 2 (length pair)))
      (error "rayforce: group: aggs must be [input-op agg-keyword] pairs"))
    (check-op (first pair) g)
    (unless (get AGG-OPS (last pair))
      (errorf "rayforce: group: unknown agg %q (v1 set: %q)"
              (last pair) (sorted (keys AGG-OPS)))))
  (-ok-op (ray_group (get g :ptr)
                     (ffi/write @[:ptr (length group-keys)] (-op-ids group-keys g))
                     (length group-keys)
                     (ffi/write @[:uint16 (length aggs)] (map |(get AGG-OPS (last $)) aggs))
                     (ffi/write @[:ptr (length aggs)] (seq [p :in aggs] (get (first p) :id)))
                     (length aggs))
          g "group"))

(defn/typed distinct {:args [:any :any] :ret :any} [g keys]
  "The distinct structural op: distinct rows over the key ops (of the
  graph's bound table)."
  (check-graph g)
  (unless (or (array? keys) (tuple? keys))
    (errorf "rayforce: distinct: keys must be an array of ops, got %s" (type keys)))
  (unless (pos? (length keys)) (error "rayforce: distinct: no keys"))
  (-ok-op (ray_distinct (get g :ptr)
                        (ffi/write @[:ptr (length keys)] (-op-ids keys g))
                        (length keys))
          g "distinct"))

(defn/typed -type-name {:args [:any] :ret :string} [x]
  "type alias for fns whose `type` parameter shadows the core fn (join)."
  (string (type x)))

(defn join
  "The join structural op: left/right are table ops (const-table
  nodes), lkeys/rkeys same-length key-op arrays, type one of
  :inner (default) :left :full :anti."
  [g left lkeys right rkeys &opt type]
  (default type :inner)
  (check-graph g)
  (def jt (get JOIN-TYPES type))
  (unless jt (errorf "rayforce: join: unknown type %q" type))
  (unless (and (or (array? lkeys) (tuple? lkeys))
               (or (array? rkeys) (tuple? rkeys)))
    (errorf "rayforce: join: lkeys/rkeys must be arrays of ops, got %s/%s"
            (-type-name lkeys) (-type-name rkeys)))
  (def lk (-op-ids lkeys g))
  (def rk (-op-ids rkeys g))
  (unless (= (length lk) (length rk))
    (errorf "rayforce: join: key count mismatch (%d vs %d)" (length lk) (length rk)))
  # the cross-type key fence (addendum A7.2): the
  # engine compares join keys by raw payload, so an F64-built vs
  # I64-loaded key pair silently drops every non-zero match
  # (observed pre-fix: rows=1 where 2 were expected). Row-wise
  # expressions coerce correctly - the JOIN KEY path does
  # not. Same-type keys pairwise; unknown (0) out_types pass through.
  (for i 0 (length lkeys)
    (def lt (-op-out-type (get lkeys i)))
    (def rt (-op-out-type (get rkeys i)))
    (when (and (not= 0 lt) (not= 0 rt) (not= lt rt))
      (errorf "rayforce: join: key %d mixes %s and %s columns - the engine compares join keys by raw payload and silently drops non-zero matches; build both key sides in one type"
              i (or (get TAG-NAMES lt) (string lt)) (or (get TAG-NAMES rt) (string rt)))))
  (-ok-op (ray_join (get g :ptr)
                    (get (check-op left g) :id)
                    (ffi/write @[:ptr (length lk)] lk)
                    (get (check-op right g) :id)
                    (ffi/write @[:ptr (length rk)] rk)
                    (length lk) jt)
          g "join"))

(defn/typed head {:args [:any :any :number] :ret :any} [g input n]
  "The first n rows of the table op (n clamped to the row count)."
  (check-graph g)
  (unless (and (>= n 0) (= n (math/round n)) (<= n 9007199254740992))
    (errorf "rayforce: head: n must be a non-negative integer no greater than 2^53, got %q" n))
  (-ok-op (ray_head (get g :ptr) (get (check-op input g) :id) n) g "head"))

(defn/typed tail {:args [:any :any :number] :ret :any} [g input n]
  "The last n rows of the table op (n clamped to the row count)."
  (check-graph g)
  (unless (and (>= n 0) (= n (math/round n)) (<= n 9007199254740992))
    (errorf "rayforce: tail: n must be a non-negative integer no greater than 2^53, got %q" n))
  (-ok-op (ray_tail (get g :ptr) (get (check-op input g) :id) n) g "tail"))

(defn/typed optimize {:args [:any :any] :ret :any} [g root]
  "The optimizer pass: a new root op with the plan optimized
  (constant folding, predicate pushdown - the engine's own pass)."
  (check-graph g)
  (-ok-op (ray_optimize (get g :ptr) (get (check-op root g) :id)) g "optimize"))

(defn/typed execute {:args [:any :any] :ret :table} [g root]
  "Execute the plan: the result table handle (owned; the engine's
  error object - malformed plans raise typed errors, never crash -
  is extracted, freed and raised). The graph stays usable; the result
  survives graph close. The root must be table-node
  shaped (addendum A7.3): a bare column op as root returns the
  engine's bare VECTOR, which read as a table is an empty result -
  silently wrong, now a validation raise (observed pre-fix: nrows=0,
  ncols=0, no error; select/group/filter roots are table nodes)."
  (check-graph g)
  (def result (err! (ray_execute (get g :ptr) (get (check-op root g) :id)) "execute"))
  (unless (= RAY-TABLE (ray_obj_type result))
    (ray_release result)  # the acquired ref releases on every raise path
    (errorf "rayforce: execute: root must be a table node (const-table/filter/select/group/...) - a bare column op produces a vector, not a table"))
  (make-table result))

#==------------------------------------------------------------------------==#
# Stress tier (internal - the smoke's leak-counting lane; contract
# section 12. Not public surface: the defbinds above are importable
# raw, this helper wraps the trace scope)
#==------------------------------------------------------------------------==#

(defn/typed -trace-net {:args [:function] :ret :tuple} [thunk]
  "Run a stress cycle inside an engine memory trace; returns
  [net-bytes alloc-count free-count result]. The thunk catches its
  own errors (an escaped error would leave the trace active
  process-wide - one scope at a time, heap.h:163-165)."
  (unless (ray_mem_trace_begin)
    (error "rayforce: -trace-net: a trace scope is already active"))
  (def out (buffer/new-filled 48 0))
  (def result (try (thunk) ([e] e)))
  (ray_mem_trace_end out)
  (def tr (ffi/read trace-struct out))
  [(get tr 4) (get tr 0) (get tr 1) result])

#==------------------------------------------------------------------------==#
# Parquet read (contract sections 1, 3, 5)
#==------------------------------------------------------------------------==#

(defn/typed -check-batch-types {:args [:any] :ret :nil} [tbl]
  "Deferred-type fence on parquet tables (contract section 5): every
  column must be I64 or F64 - a STR/SYM (or other-typed) column in
  ANY batch raises the deferred class loud, never a coerced or
  shortened read."
  (def ptr (get tbl :ptr))
  (def n (int/to-number (ray_table_ncols ptr)))
  (for i 0 n
    (def col (ray_table_get_col_idx ptr i))
    (when (nil? col) (errorf "rayforce: parquet column %d missing" i))
    (def tag (ray_obj_type col))
    (unless (or (= RAY-I64 tag) (= RAY-F64 tag))
      (def nm (or (get TAG-NAMES tag) (string tag)))
      (errorf "rayforce: parquet: unsupported column type: %s - deferred" nm))))

(defn parquet-rows
  "An array of table handles: every parquet batch in the file (batch
  rows per table, default 65536, an integer 1..65536). The reader is
  closed before returning; nothing survives on an error path. Schema
  rejection (DECIMAL/nested - the engine's flat-primitive rule) and
  deferred column types (STR/SYM) raise the engine's exact text."
  [path &opt batch]
  (default batch 65536)
  (unless (and (string? path) (pos? (length path)))
    (errorf "rayforce: parquet-rows: expected a file path, got %s" (type path)))
  (unless (and (number? batch) (= batch (math/round batch)) (>= batch 1) (<= batch 65536))
    (errorf "rayforce: batch must be an integer in 1..65536, got %q" batch))
  (def out (ffi/write :ptr nil))
  (err! (ray_parquet_open path nil batch out) "parquet open")
  (def reader (ffi/read :ptr out))
  (def batches @[])
  # reader + every collected table handle is closed on every exit path
  (defer (ray_parquet_close reader)
    (defn push-batch [t]
      (def h (make-table t))
      (array/push batches h)
      # the deferred-type check raises AFTER the handle is registered,
      # so the cleanup below reclaims it
      (-check-batch-types h))
    (defn bail [e]
      (each h batches (:close h))
      (error e))
    (try
      (while true
        (def p (ray_parquet_next reader))
        (when (nil? p) (break))
        (push-batch (err! p "parquet next")))
      ([e] (bail e))))
  batches)
