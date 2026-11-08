// janet-rayforce ownership protocol - Quint specification
// v1.1, 2026-11-07 (extended to the binding's 3.0.2 surface). v1.0,
// 2026-10-16, first Quint spec in the jenny stack.
//
// Models the binding's reference protocol over the Rayforce C ABI
// (v3.0.2, installed-header pin). The protocol, from the api-census
// ownership table:
//   - every acquired ref is released exactly once, on all paths;
//   - value refs are released with ray_release;
//   - table handles close with ray_release, graph handles with
//     ray_graph_free (the bound table survives), parquet readers with
//     ray_parquet_close - the close family must match the handle type;
//   - error objects are freed with ray_error_free (ray_release is a
//     deliberate no-op on error objects);
//   - consuming calls (ray_table_add_col class) transfer the caller's
//     ref to their return value - to the result on success, to the
//     error object on failure - so the caller releases what the call
//     RETURNED, never the stale handle it passed;
//   - ray_table_get_col / ray_table_get_col_idx return BORROWED refs
//     (contract addendum A3): the caller never releases them, their
//     lifetime is bounded by the owning table handle, and
//     ray_retain promotes one to an owned ref (the engine-side merge);
//   - ray_vec_concat returns a NEW owned vec without consuming its
//     inputs (contract addendum A22.3): the merge retains or borrows
//     the source column, concatenates, and releases the old
//     accumulator;
//   - a decoded STR value is COPIED into a Janet-owned string; the
//     engine's string pool stays with the table handle, so the copy
//     survives the handle's close and carries no engine refcount
//     (contract addendum A13).
//
// The empirical arm of this invariant is the stress loop (see
// specs/api-contract.md section 12); this spec is the checked arm.

module rayforceOwnership {

  // Abstract ref ids. Small universe: six ids keep the state space
  // small while covering every protocol interleaving the invariants
  // distinguish (each id has one of six protocol states - the
  // symmetry beyond that adds nothing).
  val Universe = Set(1, 2, 3, 4, 5, 6)

  // Protocol states for a ref id:
  //   live       - held by the caller as an owned value ref
  //   errLive    - held by the caller as an error object
  //   borrowed   - held by the caller as a BORROW (get_col/get_col_idx);
  //                never released by the caller, dies with its owner
  //   dead       - a borrow invalidated when its owner handle closed
  //   janetOwned - a decoded copy owned by Janet, outside the engine's
  //                refcount entirely (nothing to release; survives close)
  //   freed      - released exactly once, never touchable again
  var live: Set[int]
  var errLive: Set[int]
  var borrowed: Set[int]
  var dead: Set[int]
  var janetOwned: Set[int]
  var freed: Set[int]

  // Handle kind and close family per ref id ("none" before a ref is
  // touched). kinds is the owned ref's type; freedVia records which
  // close family retired it, so a mismatched pairing is observable.
  var kinds: int -> str
  var freedVia: int -> str
  // Owning table handle for a borrowed ref (0 = none).
  var borrowedOwner: int -> int

  val touched =
    live.union(errLive).union(borrowed).union(dead)
      .union(janetOwned).union(freed)

  // Close families: table and vector values close with ray_release,
  // graph handles with ray_graph_free, parquet readers with
  // ray_parquet_close, error objects with ray_error_free.
  pure def closeFamilyOf(k: str): str =
    if (k == "graph") "graph"
    else if (k == "reader") "reader"
    else if (k == "error") "error"
    else "release"

  pure def disjoint(a: Set[int], b: Set[int]): bool = a.intersect(b) == Set()

  action init = all {
    live' = Set(),
    errLive' = Set(),
    borrowed' = Set(),
    dead' = Set(),
    janetOwned' = Set(),
    freed' = Set(),
    kinds' = Universe.mapBy(_ => "none"),
    freedVia' = Universe.mapBy(_ => "none"),
    borrowedOwner' = Universe.mapBy(_ => 0),
  }

  // Acquire a fresh owned value ref (constructor / execute result).
  // ray_table_get_col / _idx are NOT acquired this way - they are
  // borrowed (borrowRef), and releasing one corrupts the heap (A3).
  action acquire =
    nondet r = Universe.exclude(touched).oneOf();
    all {
      live' = live.union(Set(r)),
      errLive' = errLive,
      borrowed' = borrowed,
      dead' = dead,
      janetOwned' = janetOwned,
      freed' = freed,
      kinds' = kinds.set(r, "vector"),
      freedVia' = freedVia,
      borrowedOwner' = borrowedOwner,
    }

  // Acquire a fresh owned HANDLE (make-table / make-graph / parquet
  // open). The kind fixes which close family is legal for it.
  action acquireHandle(kind) =
    nondet r = Universe.exclude(touched).oneOf();
    all {
      live' = live.union(Set(r)),
      errLive' = errLive,
      borrowed' = borrowed,
      dead' = dead,
      janetOwned' = janetOwned,
      freed' = freed,
      kinds' = kinds.set(r, kind),
      freedVia' = freedVia,
      borrowedOwner' = borrowedOwner,
    }

  // Receive an error object from an engine call (not a consume).
  action receiveError =
    nondet e = Universe.exclude(touched).oneOf();
    all {
      live' = live,
      errLive' = errLive.union(Set(e)),
      borrowed' = borrowed,
      dead' = dead,
      janetOwned' = janetOwned,
      freed' = freed,
      kinds' = kinds.set(e, "error"),
      freedVia' = freedVia,
      borrowedOwner' = borrowedOwner,
    }

  // Close an owned value or table ref with ray_release. Closing a
  // TABLE also invalidates every borrow it owns - a borrow's lifetime
  // is bounded by its handle (A3).
  action releaseValue(r) = all {
    r.in(live),
    (kinds.get(r) == "vector") or (kinds.get(r) == "table"),
    live' = live.exclude(Set(r)),
    errLive' = errLive,
    borrowed' = borrowed.exclude(borrowed.filter(b => borrowedOwner.get(b) == r)),
    dead' = dead.union(borrowed.filter(b => borrowedOwner.get(b) == r)),
    janetOwned' = janetOwned,
    freed' = freed.union(Set(r)),
    kinds' = kinds,
    freedVia' = freedVia.set(r, "release"),
    borrowedOwner' = borrowedOwner,
  }

  // Close a graph handle with ray_graph_free (the bound table survives).
  action freeGraph(r) = all {
    r.in(live),
    kinds.get(r) == "graph",
    live' = live.exclude(Set(r)),
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed.union(Set(r)),
    kinds' = kinds,
    freedVia' = freedVia.set(r, "graph"),
    borrowedOwner' = borrowedOwner,
  }

  // Close a parquet reader with ray_parquet_close.
  action closeReader(r) = all {
    r.in(live),
    kinds.get(r) == "reader",
    live' = live.exclude(Set(r)),
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed.union(Set(r)),
    kinds' = kinds,
    freedVia' = freedVia.set(r, "reader"),
    borrowedOwner' = borrowedOwner,
  }

  // Free an error object: ray_error_free, exactly once. The protocol
  // NEVER uses ray_release here - that is the no-op trap.
  action freeError(e) = all {
    e.in(errLive),
    live' = live,
    errLive' = errLive.exclude(Set(e)),
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed.union(Set(e)),
    kinds' = kinds,
    freedVia' = freedVia.set(e, "error"),
    borrowedOwner' = borrowedOwner,
  }

  // Consuming call, success path: the caller's ref is transferred to
  // the return value - the SAME ref comes back (the engine returns the
  // same pointer), so it stays live; the caller releases the returned
  // handle exactly once, never the stale one plus the returned one.
  action consumeOk(r) = all {
    r.in(live),
    live' = live,
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed,
    kinds' = kinds,
    freedVia' = freedVia,
    borrowedOwner' = borrowedOwner,
  }

  // Consuming call, failure path: the caller's ref is already gone
  // (consumed on the error path) and an error object comes back,
  // which must be error_freed. A consumed table also invalidates its
  // borrows.
  action consumeFail(r) =
    nondet e = Universe.exclude(touched).oneOf();
    all {
      r.in(live),
      live' = live.exclude(Set(r)),
      errLive' = errLive.union(Set(e)),
      borrowed' = borrowed.exclude(borrowed.filter(b => borrowedOwner.get(b) == r)),
      dead' = dead.union(borrowed.filter(b => borrowedOwner.get(b) == r)),
      janetOwned' = janetOwned,
      freed' = freed.union(Set(r)),
      kinds' = kinds.set(e, "error"),
      freedVia' = freedVia.set(r, "consume"),
      borrowedOwner' = borrowedOwner,
    }

  // Borrow a column from a live table: ray_table_get_col /
  // ray_table_get_col_idx return a BORROWED ref (A3). No ownership
  // moves; the borrow is invalidated when the owning handle closes.
  action borrowRef(b, t) = all {
    b.in(Universe.exclude(touched)),
    t.in(live),
    kinds.get(t) == "table",
    b != t,
    live' = live,
    errLive' = errLive,
    borrowed' = borrowed.union(Set(b)),
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed,
    kinds' = kinds.set(b, "borrowed"),
    freedVia' = freedVia,
    borrowedOwner' = borrowedOwner.set(b, t),
  }

  // ray_retain: promote a borrowed ref to an owned one (the caller may
  // then pass it to a consuming call or release it). The A22.3 merge
  // path retains the first batch's column this way.
  action retainBorrowed(r) = all {
    r.in(borrowed),
    live' = live.union(Set(r)),
    errLive' = errLive,
    borrowed' = borrowed.exclude(Set(r)),
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed,
    kinds' = kinds.set(r, "vector"),
    freedVia' = freedVia,
    borrowedOwner' = borrowedOwner.set(r, 0),
  }

  // ray_vec_concat(acc, col) returns a NEW owned vector and consumes
  // NEITHER input (A22.3). The binding releases the old accumulator
  // after the merge; the source column stays borrowed from its table.
  action concatMerge(acc, col, out) = all {
    acc.in(live),
    kinds.get(acc) == "vector",
    col.in(borrowed),
    out.in(Universe.exclude(touched)),
    out != acc,
    live' = live.union(Set(out)).exclude(Set(acc)),
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed.union(Set(acc)),
    kinds' = kinds.set(out, "vector"),
    freedVia' = freedVia.set(acc, "release"),
    borrowedOwner' = borrowedOwner,
  }

  // Decode a borrowed column (STR path, A13): every value is COPIED
  // into a Janet-owned immutable string. The copy has no engine
  // refcount, is never released to the engine, and survives the
  // source handle's close (the string pool belongs to the handle).
  action decodeCopy(src, out) = all {
    src.in(borrowed),
    out.in(Universe.exclude(touched)),
    live' = live,
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned.union(Set(out)),
    freed' = freed,
    kinds' = kinds.set(out, "janet"),
    freedVia' = freedVia,
    borrowedOwner' = borrowedOwner,
  }

  // Single-choice step actions (step arms; named so the tests can
  // chain them deterministically). Each pick is filtered to the kind
  // its action accepts, so a run never has to reject a sampled id.
  action doRelease =
    nondet r = live.filter(x => (kinds.get(x) == "vector") or (kinds.get(x) == "table")).oneOf();
    releaseValue(r)
  action doFreeError =
    nondet e = errLive.oneOf();
    freeError(e)
  action doConsumeOk =
    nondet r = live.oneOf();
    consumeOk(r)
  action doConsumeFail =
    nondet r = live.oneOf();
    consumeFail(r)
  action doAcquireHandle =
    nondet k = Set("table", "graph", "reader", "vector").oneOf();
    acquireHandle(k)
  action doFreeGraph =
    nondet r = live.filter(x => kinds.get(x) == "graph").oneOf();
    freeGraph(r)
  action doCloseReader =
    nondet r = live.filter(x => kinds.get(x) == "reader").oneOf();
    closeReader(r)
  action doBorrow =
    nondet t = live.filter(x => kinds.get(x) == "table").oneOf();
    nondet b = Universe.exclude(touched).oneOf();
    borrowRef(b, t)
  action doRetain =
    nondet r = borrowed.oneOf();
    retainBorrowed(r)
  action doConcat =
    nondet acc = live.filter(x => kinds.get(x) == "vector").oneOf();
    nondet col = borrowed.oneOf();
    nondet out = Universe.exclude(touched).oneOf();
    concatMerge(acc, col, out)
  action doDecode =
    nondet src = borrowed.oneOf();
    nondet out = Universe.exclude(touched).oneOf();
    decodeCopy(src, out)
  action doCloseTable =
    nondet r = live.filter(x => kinds.get(x) == "table").oneOf();
    releaseValue(r)

  // Stutter: the protocol can always do nothing (deadlock guard).
  action idle = all {
    live' = live,
    errLive' = errLive,
    borrowed' = borrowed,
    dead' = dead,
    janetOwned' = janetOwned,
    freed' = freed,
    kinds' = kinds,
    freedVia' = freedVia,
    borrowedOwner' = borrowedOwner,
  }

  action step = any {
    acquire,
    acquireHandle("table"),
    acquireHandle("graph"),
    acquireHandle("reader"),
    receiveError,
    doRelease,
    doFreeGraph,
    doCloseReader,
    doFreeError,
    doConsumeOk,
    doConsumeFail,
    doBorrow,
    doRetain,
    doConcat,
    doDecode,
    idle,
  }

  // ---- Invariants ----

  // Partition: every touched ref id sits in at most one state.
  val partition = and {
    (live.intersect(errLive)) == Set(),
    (live.intersect(freed)) == Set(),
    (errLive.intersect(freed)) == Set(),
    disjoint(borrowed, live.union(errLive).union(freed)),
    disjoint(dead, live.union(errLive).union(borrowed).union(freed)),
  }

  // No zombie use: a freed ref never re-enters any live state. This
  // is what makes the two census traps structurally impossible: a
  // stale handle after a consume cannot be released again, and an
  // error object can never pass through the value-release path.
  val noZombie = and {
    (freed.intersect(live)) == Set(),
    (freed.intersect(errLive)) == Set(),
  }

  // A borrow is never released by the caller, and it is always owned
  // by a LIVE table handle: its lifetime is bounded by the handle.
  val borrowLifecycle = and {
    (borrowed.intersect(freed)) == Set(),
    borrowed.forall(b => borrowedOwner.get(b).in(live)),
  }

  // The close family must match the handle type: a table or vector
  // closes with ray_release, a graph with ray_graph_free, a reader
  // with ray_parquet_close, an error object with ray_error_free.
  // Consumed refs are retired by the engine (`consume`), not a close.
  val closeFamilyMatches =
    freed.forall(r =>
      freedVia.get(r) == "consume"
      or freedVia.get(r) == closeFamilyOf(kinds.get(r)))

  // A borrow invalidated by its owner's close is gone for good - it
  // is never re-released, re-owned, or reused.
  val noDeadRevival =
    dead.intersect(live.union(errLive).union(borrowed).union(freed)) == Set()

  // A decoded copy is Janet-owned: no engine state can hold it, and a
  // close never retires it (nothing to release, the pool is the
  // handle's).
  val janetCopy =
    janetOwned.intersect(live.union(errLive).union(borrowed).union(dead).union(freed)) == Set()

  val inv = and {
    partition,
    noZombie,
    borrowLifecycle,
    closeFamilyMatches,
    noDeadRevival,
    janetCopy,
  }

  // ---- Protocol tests (scenarios the census flagged as traps) ----

  // Trap 1: the stale handle after a successful consume - the ref the
  // caller passed is freed; only the returned ref is live.
  run staleHandleAfterConsume = {
    init.then(acquire).then(doConsumeOk)
      .expect(inv)
  }

  // Trap 2: the error-object no-op trap - only freeError retires an
  // errLive ref; releaseValue requires live membership.
  run releaseOnErrorDisabled = {
    init.then(receiveError).then(doFreeError)
      .expect(inv.and(errLive == Set()))
  }

  // Happy path: acquire -> consume(success) -> release the returned ref.
  run consumeSuccessCycle = {
    init.then(acquire).then(doConsumeOk).then(doRelease)
      .expect(inv.and(live == Set()))
  }

  // Error path: acquire -> consume(failure) -> free the error object.
  run consumeErrorCycle = {
    init.then(acquire).then(doConsumeFail).then(doFreeError)
      .expect(inv.and(errLive == Set()))
  }

  // Borrowed-read cycle: table handle -> borrowed column -> decode
  // copy -> close the table. The borrow dies with the handle (never
  // released); the decoded copy outlives it with no engine refcount.
  run borrowReadCycle = {
    init.then(acquireHandle("table")).then(doBorrow).then(doDecode).then(doCloseTable)
      .expect(inv.and(borrowed == Set()).and(dead != Set()).and(janetOwned != Set()))
  }

  // Engine-side merge cycle (A22.3): batch-1 column borrowed and
  // retained to an owned accumulator; batch-2 column borrowed; concat
  // returns a new owned vector and the old accumulator is released.
  run retainConcatCycle = {
    init
      .then(acquireHandle("table"))
      .then(doBorrow)
      .then(doRetain)
      .then(acquireHandle("table"))
      .then(doBorrow)
      .then(doConcat)
      .expect(inv.and(freed != Set()).and(borrowed != Set()))
  }

  // Close-family cycles: each handle type retires through its own
  // family and the close-family invariant holds.
  run graphCloseCycle = {
    init.then(acquireHandle("graph")).then(doFreeGraph)
      .expect(inv.and(live == Set()).and(freed != Set()))
  }

  run readerCloseCycle = {
    init.then(acquireHandle("reader")).then(doCloseReader)
      .expect(inv.and(live == Set()).and(freed != Set()))
  }
}
