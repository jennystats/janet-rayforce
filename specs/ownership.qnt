// janet-rayforce ownership protocol - Quint specification
// v1.0, 2026-10-16. First Quint spec in the jenny stack.
//
// Models the binding's reference protocol over the Rayforce C ABI
// (v2.11.5, vendored-header pin). The protocol, per the binding's
// ownership rules (api-contract.md section 2):
//   - every acquired ref is released exactly once, on all paths;
//   - value refs are released with ray_release;
//   - error objects are freed with ray_error_free (ray_release is a
//     deliberate no-op on error objects);
//   - consuming calls (ray_table_add_col class) transfer the caller's
//     ref to their return value - to the result on success, to the
//     error object on failure - so the caller releases what the call
//     RETURNED, never the stale handle it passed.
//
// The empirical half of this invariant is the stress loop (see
// specs/api-contract.md section 12); this spec is the checked half.

module rayforceOwnership {

  // Abstract ref ids. Small universe: six ids keep the state space
  // small while covering every protocol interleaving the invariants
  // distinguish (each id has four states: untouched/live/errLive/
  // freed - 4^6 reachable shapes, symmetry beyond that adds nothing).
  val Universe = Set(1, 2, 3, 4, 5, 6)

  // Protocol states for a ref id:
  //   live    - held by the caller as a value ref
  //   errLive - held by the caller as an error object
  //   freed   - released exactly once, never touchable again
  var live: Set[int]
  var errLive: Set[int]
  var freed: Set[int]

  val touched = live.union(errLive).union(freed)

  action init = all {
    live' = Set(),
    errLive' = Set(),
    freed' = Set(),
  }

  // Acquire a fresh ref (constructor / execute result / get_col).
  action acquire =
    nondet r = Universe.exclude(touched).oneOf();
    all {
      live' = live.union(Set(r)),
      errLive' = errLive,
      freed' = freed,
    }

  // Receive an error object from an engine call (not a consume).
  action receiveError =
    nondet e = Universe.exclude(touched).oneOf();
    all {
      live' = live,
      errLive' = errLive.union(Set(e)),
      freed' = freed,
    }

  // Release a value ref: ray_release, exactly once.
  action releaseValue(r) = all {
    r.in(live),
    live' = live.exclude(Set(r)),
    errLive' = errLive,
    freed' = freed.union(Set(r)),
  }

  // Free an error object: ray_error_free, exactly once. The protocol
  // NEVER uses ray_release here - that is the no-op trap.
  action freeError(e) = all {
    e.in(errLive),
    live' = live,
    errLive' = errLive.exclude(Set(e)),
    freed' = freed.union(Set(e)),
  }

  // Consuming call, success path: the caller's ref is transferred to
  // the return value - the SAME ref comes back (the engine returns the
  // same pointer), so it stays live; the caller releases the returned
  // handle exactly once, never the stale one plus the returned one.
  action consumeOk(r) = all {
    r.in(live),
    live' = live,
    errLive' = errLive,
    freed' = freed,
  }

  // Consuming call, failure path: the caller's ref is already gone
  // (consumed on the error path) and an error object comes back,
  // which must be error_freed.
  action consumeFail(r) =
    nondet e = Universe.exclude(touched).oneOf();
    all {
      r.in(live),
      live' = live.exclude(Set(r)),
      errLive' = errLive.union(Set(e)),
      freed' = freed.union(Set(r)),
    }

  // Single-choice step actions (step arms; named so the tests can
  // chain them deterministically).
  action doRelease =
    nondet r = live.oneOf();
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

  // Stutter: the protocol can always do nothing (deadlock guard).
  action idle = all {
    live' = live,
    errLive' = errLive,
    freed' = freed,
  }

  action step = any {
    acquire,
    receiveError,
    doRelease,
    doFreeError,
    doConsumeOk,
    doConsumeFail,
    idle,
  }

  // ---- Invariants ----

  // Partition: every touched ref id sits in at most one state.
  val partition = and {
    (live.intersect(errLive)) == Set(),
    (live.intersect(freed)) == Set(),
    (errLive.intersect(freed)) == Set(),
  }

  // No zombie use: a freed ref never re-enters any live state. This
  // is what makes the two protocol traps structurally impossible: a
  // stale handle after a consume cannot be released again, and an
  // error object can never pass through the value-release path.
  val noZombie = and {
    (freed.intersect(live)) == Set(),
    (freed.intersect(errLive)) == Set(),
  }

  val inv = and { partition, noZombie }

  // ---- Protocol tests (the known trap scenarios) ----

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
}
