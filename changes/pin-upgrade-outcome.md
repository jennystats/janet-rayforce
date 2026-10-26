# CR outcome - janet-rayforce engine pin upgrade v2.11.5 -> v3.0.1

Session: 2026-10-26, branch `feature/pin-upgrade-v301` from `main` @ `16e3d76`.
CR input: `pin-upgrade-prompt.md`. No push; version bump is the last commit and
is flagged for owner approval below.

## Verdict

The upgrade is a re-verification CR, not a code-change CR. The ABI delta is
additive; no janet-side change was required. All five phase gates passed, with
one CR premise corrected (see "Corrected premise"): the CR's stated reason for
the upgrade - that #934's null-model fix landed in v3.0.1 - is false, because
upstream rejected #934. The engine pin upgrade stands on other grounds, but
**the null model does not become "current" by this upgrade; it was already
correct.**

## Phase 0 - ABI delta assessment. GATE: PASS

Fetched both tarballs from the documented URL
(`https://api.github.com/repos/RayforceDB/rayforce/tarball/v<VER>`). The
v2.11.5 tarball reproduces the existing pin sha256 exactly, which validates
the fetch path and the pin infrastructure.

Tarball sha256:

| version | sha256 |
|---|---|
| v2.11.5 | `fec660bb01cfd53cbc816da82e89c61c7fc803ce4c56f64fb3ee83cc04079406` |
| v3.0.1 | `3a42998400ed4136558e65ec3386e26548994db76e0c3ed8f9b52f2c4487e335` |

### Header delta (the four vendored ABI pins)

| header | v2.11.5 lines | v3.0.1 lines | status | called-symbol decls touched |
|---|---|---|---|---|
| `include/rayforce.h` | 935 | 976 | CHANGED | none removed; 5 added |
| `src/ops/ops.h` | 995 | 1027 | CHANGED | none removed; 5 added |
| `src/io/parquet.h` | 58 | 58 | **byte-identical** | none |
| `src/mem/heap.h` | 671 | 699 | CHANGED | none removed; 6 added |

New header pins:

```
include/rayforce.h  c73c85c94f3dacdf9b437114f1794233823c50c0fb6d122cd925650e65bb5158
src/ops/ops.h       a82e47e96bdea0794fc0123d26a29e2bc0497e92d83716b3ac902a4b239d0bd8
src/io/parquet.h    0b34603ada9b8699226be029fc8ba7483be65293a908098b5937222d97acf290  (UNCHANGED)
src/mem/heap.h      34a9ce98abc5c37c111b70ed77d41a321bd9f7b93f8d92d8657e51a2e96b68ae
```

Across the wider tree, 40 headers changed and 15 are new (mostly
encoded-column and store internals: `enc*`, `fsst`, `colrange`, `colbind`,
`colgather`, `strdom`).

### Exported-symbol comparison (nm on both built archives)

Built both engines with the pinned own-CFLAGS recipe and compared
`nm -D --defined-only`.

| metric | count |
|---|---|
| symbols v2.11.5 -> v3.0.1 | 1570 -> 1989 |
| added | 424 |
| removed | **5** |

Removed symbols (none is called by the binding):

```
ray_col_stream_hash_all
ray_col_stream_hash_one
ray_col_stream_hash_wave
ray_csv_hash_upgrade_check
ray_splay_hash_column
```

### Call-site mapping (every symbol the module calls)

82 distinct `ray_*` symbols across `jennystats/rayforce.janet` and its
bindings.

| check | result |
|---|---|
| called symbols still exported by v3.0.1 | **82 / 82** |
| called symbols with changed declaration | **0** |
| called symbols whose declaration is byte-identical or comment-only changed | 82 |
| called symbols absent from all v3.0.1 headers | 0 |

Notable non-breaking changes:

- `ray_error_msg` MOVED from internal `src/core/runtime.h` to public
  `include/rayforce.h`. Same declaration. The binding was already calling it.
- `RAY_ERR_FPENV` added to the `ray_err_t` enum (appended; existing codes
  keep their values).
- `RAY_TIMESPAN 16` is a new type code in a previously unused slot. The codes
  the binding hardcodes are unchanged: `RAY_BOOL 1`, `RAY_I64 5`, `RAY_F64 7`,
  `RAY_STR 13`, `RAY_TABLE 98`.
- `ray_op_t` is **byte-identical**. The join-key fence reads `out_type` via
  `ffi/struct :uint16 :uint8 :uint8 :int8` at offset 3, which remains correct.
- `ray_t` layout changed only in comments; the binding never dereferences it,
  it only passes opaque pointers.

**Gate: no symbol the module calls was removed or changed signature. The
upgrade stays a re-verification CR.**

### Phase 0 judgement call: pin v3.0.1

Pinned v3.0.1, not a newer tag: the GitHub tag list shows v3.0.1 as the newest
release. There is nothing later to prefer.

## Phase 1 - re-pin and build. GATE: PASS

`libs/install-rayforce.sh` updated: `VERSION`, `TARBALL_SHA256`, the four
`HEADER_SHA` pins. Preserved: the header-drift hard failure before any
compile, the own-CFLAGS static build, idempotence.

Two installer defects found and fixed, both of which would have failed
*silently* rather than loudly:

1. **Object suffix rename.** v3.0.1 emits `*.lib.o` where v2.11.5 emitted
   `*.rel.o`. The old link step globbed `*.rel.o`, which matched nothing - a
   glob that matches nothing passes the literal string to `cc`, producing an
   empty 6 KB `.so` at exit 0. Added `REL_OBJ_SUFFIX` plus an explicit
   empty-set failure.
2. **No post-link ABI assertion.** Added a check that the linked object
   actually exports `ray_version_major`, so a symbol-less `.so` can never be
   installed.

Also added: `DEST` override so a second pin can be installed alongside the
current one (the CR's separate-dest rail), defaulting to the old path.

### The one build-recipe deviation (owner-approved, 2026-10-26)

v3.0.1 does not compile under the preserved recipe on this box. Its new
`src/ops/colgather.c` trips clang's `-Werror=maybe-uninitialized`:

```
src/vec/str.h:123:67: error: 'off' may be used uninitialized
  inlined from 'ray_str_t_hash32' at src/vec/str.h:136:28,
  inlined from 'acc_put' at src/ops/colgather.c:139:28
src/ops/colgather.c:130:26: note: 'off' was declared here
```

Cause: `off` is an uninitialised out-param at line 130, but `ray_data(a->pool)`
on line 139 makes it defined on the only path that reads it. clang's analyzer
cannot see through the pool indirection. gcc is clean, and the v2.11.5 recipe
was gcc-era; this box's `cc` is clang.

Owner ruling: keep `-Werror`, suppress this one diagnostic. Implemented at the
narrowest available scope using the Makefile's existing
`FP_STRICT_<stem>` per-file hook:

```
'FP_STRICT_src/ops/colgather:=-Wno-maybe-uninitialized'
```

This is diagnostics-only: no effect on emitted code, optimisation or FP
results. It is commented in the installer with the file, mechanism and a
re-evaluate-at-every-bump instruction, and recorded as A13.3 in the contract.
Verified in the build log: the flag appears on the `colgather.lib.o` compile
line only.

### Build and install

```
DEST=$HOME/.local/lib/rayforce-v301 bash libs/install-rayforce.sh
```

Result: sha256 OK, `vendored-header cross-check: 4/4 byte-identical`, clean
build, installed to `~/.local/lib/rayforce-v301/librayforce.so` (1989 symbols,
identical set to the Phase 0 standalone build).

The v2.11.5 rollback install was verified untouched by sha256 before and after
(`27b80598...`).

## Engine identity - which library the cells actually load

Verified, not assumed. The module resolves `$RAYFORCE_LIB`, then
`~/.local/lib/rayforce/librayforce.so`, then the bare soname. Confirmed by
reading `/proc/self/maps` in-process:

| condition | loaded file | reported version |
|---|---|---|
| no override | `~/.local/lib/rayforce/librayforce.so` | 2.11.5 |
| `RAYFORCE_LIB=.../rayforce-v301/librayforce.so` | `~/.local/lib/rayforce-v301/librayforce.so` | 3.0.1 |

Module resolution was also verified: `run_tests.sh` prepends the repo directory
to `JANET_PATH`, and a marker-module probe confirmed the first entry wins, so
the repo's `jennystats/rayforce.janet` loads - not the hot-tools copy symlinked
into `~/.local/lib/janet/jennystats/`. (The two copies differ in comments
only; the hot-tools one carries extra battery citations.)

## Phase 2 - contract re-run. GATE: PASS

### Instrument

`test/percells.janet` runs the smoke file's 198 top-level non-definition
expressions individually, in ONE process, preserving the file's own execution
model (ordered shared defs). Both engines run under the same instrument, so
instrument-induced state cancels in the diff.

Methodology note, recorded for the ratifier: a section-split harness
(`test/percell.janet`, since removed) was tried first and **disproven** - it
produced 8 false FAILs against the known-green v2.11.5 baseline, because the
smoke file defines helpers (`subprobe`, `net0`) inside sections that later
sections use, and relies on 104 interleaved top-level defs. Per the owner
ruling, fresh-process confirmation is reserved for cells whose status actually
differs.

### Result

| engine | probes | pass | fail |
|---|---|---|---|
| v2.11.5 | 198 | 198 | 0 |
| v3.0.1 | 198 | 197 | 1 |

The single delta:

```
idx 3: (assert-eq [2 11 5] (rayforce/engine-version) "engine version 2.11.5")
  v2115: PASS
  v301 : FAIL - assert engine version 2.11.5: expected (2 11 5), got (3 0 1)
```

This is the hardcoded pin assert, not a behavioural change. It was replaced
with a pin-aware assert (`RAYFORCE_EXPECT_VERSION` override, default
`[3 0 1]`), after which both engines pass the full file:

```
RAYFORCE_LIB=.../rayforce-v301/librayforce.so ./run_tests.sh  # RESULT: pass
RAYFORCE_EXPECT_VERSION=2.11.5 ./run_tests.sh                 # RESULT: pass
```

Every null-model, parquet, ownership, guard and lifecycle cell has an
identical verdict on both engines.

### Corrected premise - #934 is NOT the reason for this upgrade

The CR states the null-model change is expected because "#934's fix landed in
the v3.0.1 line". That is not what happened. Upstream issue #934
("Proposal: R-style NA payload for F64 - distinguishing missing from NaN") is
**closed as NOT ADOPTED**. The maintainer's closing comment is explicit: the
"existing single-null float model" is retained, non-finite computed results
remain null, and there is "no sentinel implementation or new import mapping to
promise".

So there was no null-model change to detect, which is exactly what the
measured result shows. Behavioural confirmation on both engines: writing a NaN
into an F64 column and writing `nil` both read back as `nil` - the collapse is
identical on 2.11.5 and 3.0.1.

The project's own contract already recorded this correctly (section 4: "the
single-null float model is retained, NaN/NA are not distinguished"). The CR
prompt was wrong, not the contract. The contract's only stale line - a
reference to a "#934 semantics decision" as if still pending - was updated to
state that #934 is closed as retained behaviour.

What the upgrade does buy, verified: #834 (`fix(dict): release distinct error
values on failure`, closed 2026-10-16) is present in v3.0.1 source. v2.11.5
released `vals` only when it was not an error; v3.0.1 adds the `vals != keys`
aliasing guard and calls `ray_error_free(vals)` on the distinct-error path.
This is a genuine leak fix on the ownership surface, and the Phase 3 ownership
runs pass on it.

## Phase 3 - Quint ownership re-verification. GATE: PASS

```
quint test specs/ownership.qnt \
  --match='^(staleHandleAfterConsume|releaseOnErrorDisabled|consumeSuccessCycle|consumeErrorCycle|init)$' \
  --out /tmp/quint-ownership.json
```

Result: `passed = [init, staleHandleAfterConsume, releaseOnErrorDisabled,
consumeSuccessCycle, consumeErrorCycle]`, `failed = []`, `errors = 0`.

The spec itself is byte-unchanged (CR rail). Its header comment still cites the
v2.11.5 pin; this is noted as a follow-up rather than edited in-CR.

### Instrument defect found (important for future gates)

`quint test <spec>` on this box (quint 0.33.0) is a **vacuous pass**: it
prints only the module name and exits rc=0 even when a run's `.expect` is
false, because without `--match` it collects ZERO runs. This was proven by
running a deliberately failing spec, which also reported rc=0 with empty
output; the `--out` JSON shows `"passed":[], "failed":[]`.

A Phase 3 "quint test: green" claim made without `--match` is worthless. The
oracle used here is proven live: the identical invocation fails the
deliberately broken spec, and `--match='.*'` is also wrong because it matches
vals and actions, which "fail" as tests since they are not runnable sequences.
Match run names explicitly and read the `--out` JSON (or grep stderr; the CLI
also exits 0 on parse errors).

## Phase 4 - parquet bitwise-exactness + precision spot-check. GATE: PASS

`test/phase4-check.janet` compares RAW IEEE-754 bit patterns, not numeric
equality, so a one-ulp drift cannot hide behind a tolerant compare.

| check | v2.11.5 | v3.0.1 |
|---|---|---|
| f64 parquet bitwise (`f64.parquet`, 5 values) | PASS | PASS, patterns IDENTICAL |
| i64 parquet exact (2^53 band) | PASS | PASS, values IDENTICAL |
| F64 in-memory bitwise, 8 edge values | PASS | PASS, patterns IDENTICAL |
| `0.1 + 0.2` (fast-math tripwire) | PASS | PASS, IDENTICAL |
| computed column sum bitwise | PASS | PASS, IDENTICAL |

Edge values exercised: `0.1`, `0.2`, `0.30000000000000004`, `-0.0`, `1e300`,
`-1e-320` (subnormal), `2.2250738585072014e-308` (minimum normal), and
`1.7976931348623157e308` (DBL_MAX). Patterns, e.g.:

```
v2115 prec-bits: 3fb999999999999a 3fc999999999999a 3fd3333333333334 0000000000000000
                 7e37e43c8800759c 80000000000007e8 0010000000000000 7fefffffffffffff
v301  prec-bits: [identical]
```

`parquet.h` is byte-identical between versions, consistent with this result.
No numerics claim in the contract needs re-stating.

## Phase 5 - version bump + docs

Docs landed (`e4f2130`): README pin text and the `RAYFORCE_EXPECT_VERSION`
note; contract header, section 11, sources and new addendum A13.

**Version bump: FLAGGED FOR OWNER APPROVAL - not committed.**

`project.janet` `:version "0.1.1"` -> `"0.1.2"` is prepared but deliberately
left uncommitted, per the CR's version-bump gate. Approve and it is a one-line
commit; decline and the pin change stands on 0.1.1.

Note on `run_tests.sh` state at hand-off: with the suite's default expectation
now at 3.0.1, `./run_tests.sh` FAILs on this box until the pin is ratified,
because the default resolution path still points at the v2.11.5 install. This
is the correct failure (loud, not silent) and it disappears the moment the
owner either reruns the installer without `DEST` or sets `RAYFORCE_LIB`.
Verified both directions:

```
./run_tests.sh                                                  # FAIL (expects 3.0.1, loads 2.11.5)
RAYFORCE_LIB=.../rayforce-v301/librayforce.so ./run_tests.sh    # RESULT: pass
RAYFORCE_EXPECT_VERSION=2.11.5 ./run_tests.sh                   # RESULT: pass
```

## Commits on `feature/pin-upgrade-v301`

```
e4f2130 docs: record the v3.0.1 pin and the additive ABI delta
1c062ca test: drop the disproven section-split harness
3516767 build: re-pin rayforce to v3.0.1 with ABI-verified installer
```

No push. Version bump not committed.

## Redo commands

```bash
# Phase 0 - fetch and compare
curl -fsSL -o /tmp/v301.tgz https://api.github.com/repos/RayforceDB/rayforce/tarball/v3.0.1
sha256sum /tmp/v301.tgz            # expect 3a42998400ed4136558e65ec3386e26548994db76e0c3ed8f9b52f2c4487e335

# Phase 1 - build the candidate into a separate DEST (rollback untouched)
DEST=$HOME/.local/lib/rayforce-v301 bash libs/install-rayforce.sh

# Phase 2 - per-expression sweep, both engines, then diff the JSON
JANET_PATH="$PWD:$HOME/.local/lib/janet" janet test/percells.janet test/smoke-rayforce.janet /tmp/pc-2115.json
RAYFORCE_LIB=$HOME/.local/lib/rayforce-v301/librayforce.so JANET_PATH="$PWD:$HOME/.local/lib/janet" \
  janet test/percells.janet test/smoke-rayforce.janet /tmp/pc-301.json
# then compare the "results" arrays by idx/status

# Phase 2 - the suite proper
RAYFORCE_LIB=$HOME/.local/lib/rayforce-v301/librayforce.so ./run_tests.sh   # RESULT: pass

# Phase 3 - ownership (--match is REQUIRED, see the instrument defect above)
quint test specs/ownership.qnt \
  --match='^(staleHandleAfterConsume|releaseOnErrorDisabled|consumeSuccessCycle|consumeErrorCycle|init)$' \
  --out /tmp/quint-ownership.json

# Phase 4 - bitwise + precision, both engines
JANET_PATH="$PWD:$HOME/.local/lib/janet" janet test/phase4-check.janet /tmp/p4-2115.json
RAYFORCE_LIB=$HOME/.local/lib/rayforce-v301/librayforce.so JANET_PATH="$PWD:$HOME/.local/lib/janet" \
  janet test/phase4-check.janet /tmp/p4-301.json

# Rollback verification
sha256sum -c <<< "27b80598a18ed8eaac2c4aba449fd2aeb0e9206870ca0935fb88e1bd5919ee95  $HOME/.local/lib/rayforce/librayforce.so"
```

## Standing limitations

1. **Ratification is the owner's.** The default resolution path still loads
   v2.11.5. The switch is either a plain re-run of the installer (no `DEST`)
   or `RAYFORCE_LIB`. Until then `./run_tests.sh` fails by design.
2. **The `-Wno-maybe-uninitialized` suppression is a standing deviation.**
   Diagnostics-only, one object, but it must be re-examined at every future
   pin bump and removed if upstream or clang resolves it.
3. **`specs/ownership.qnt` header still cites v2.11.5.** Byte-unchanged per the
   CR rail that the spec is not touched. One comment line to update in a later
   CR.
4. **The Quint vacuous-pass defect is a toolchain issue, not fixed here.**
   Any relying pipeline must pass `--match` and read the `--out` JSON.
5. **Contract section 12's "bounded, 8 steps" Quint claim was not re-run as a
   state-space verification.** This CR ran the spec's protocol `run`s (Phase 3
   scope), not `quint verify` via Apalache. The ownership surface touched by
   #834 is covered by the protocol runs and the smoke suite's net-0 stress
   loop, not by a fresh model check.
6. **No macOS verification.** Unchanged from the previous pin; section 10 still
   makes no stronger claim.
