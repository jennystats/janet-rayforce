# CR PROMPT - janet-rayforce: upstream pin upgrade v2.11.5 -> v3.0.1

You are opening the rayforce pin-upgrade CR (janet-rayforce, one
session, end to end). Model tier: DeepSeek-V4.1-Flash-1017
(strong-equivalent on agentic/FFI axes - memory/model-tier-map.md).

## STEP 0 - FLOOR

Skills janet and git-workflow BEFORE anything else. This is a major
upstream bump: the work is structured in gated phases and you stop
at each gate that fails.

## GOVERNING DOCUMENTS

1. libs/install-rayforce.sh - the pin infrastructure: v2.11.5
   tarball sha256, the four vendored-header ABI pins (rayforce.h,
   ops/ops.h, io/parquet.h, mem/heap.h - a drift is a hard failure
   BEFORE any compile), own-CFLAGS static build (no -march=native,
   no fast-math: every precise-numeric contract claim is about THIS
   binary), idempotent.
2. specs/api-contract.md (v-latest, 821 lines) - the behavioural
   contract: type matrix, null model (sentinels, NaN class,
   HAS_NULLS gate - the unified null model is
   "upstream-confirmed (rayforce #934)" per the README, which is
   one reason for this upgrade: #934's fix landed in the v3.0.1
   line), error taxonomy, precision boundaries.
3. specs/ownership.qnt (180 lines) - the Quint ownership spec.
4. README.md - null-model line, ABI cross-check description,
   parquet contract (f32-seam write-side fact; read-side was
   pending #934).
5. run_tests.sh - the test entry.

## THE PROCESS (phased, gate per phase - STOP at a failed gate)

### PHASE 0 - ABI delta assessment (before any pin change)

Fetch the v3.0.1 tarball (do NOT overwrite the v2.11.5 install at
~/.local/lib/rayforce - build into a separate tree, e.g.
~/.local/lib/rayforce-v301/). Diff the four pinned headers v2.11.5
-> v3.0.1 plus a full exported-symbol comparison (nm on both
librayforce.a/.so builds). Deliverable: a delta table - added /
removed / changed functions, struct changes, enum changes - mapped
against every call site in modules/jennystats/rayforce.janet and
the shim. GATE: if any symbol the module calls was removed or
changed signature, the upgrade is a CODE-CHANGE CR, not a
re-verification CR - stop, report the delta, await a new prompt.
(There is also a phase-0 judgement call to make: whether to pin
v3.0.1 or the newest tag if a later one exists - state your pick
with reasons.)

### PHASE 1 - re-pin and build

Update install-rayforce.sh: VERSION, TARBALL_SHA256 (computed from
the fetched tarball - state the fetch URL), the four HEADER_SHA
pins (computed from the new tarball's headers). Preserve: the
header-drift hard-failure design, the own-CFLAGS static build, the
separate-dest option, idempotence. Build with the same flags.
GATE: clean build.

### PHASE 2 - contract re-run (the re-verification)

Run the full contract suite (run_tests.sh) against the v3.0.1
engine - every cell, not a sample. Per-file diffs against the
v2.11.5 baseline results: which cells changed status. Any changed
cell is a FINDING to investigate before proceeding (the null-model
cells are EXPECTED to be affected: #934's fix is the point of the
upgrade - a null-behaviour change that matches the upstream fix is
a CONFIRMED-UPGRADE result, document it against the contract text).
GATE: every cell either passes or has a documented, upstream-
traced explanation.

### PHASE 3 - Quint ownership spec re-verification

quint test on specs/ownership.qnt against the new engine (the
ownership model may be affected by the dict-error fixes: #834
"release distinct error values on failure" touches exactly the
ownership surface). GATE: green, or a documented delta mapped to
the upstream changelog.

### PHASE 4 - performance spot-check

The crossprobe measured ThorVG/Blend2D against rayforce-free
baselines, but the janet-rayforce README claims parquet reads are
"bitwise-exact" and the contract claims precision boundaries "about
THIS binary". Re-run the parquet read cells (bitwise-exactness
check) and one numeric-precision cell. If v3.0.1 changed numeric
behaviour, the contract's precision claims must be re-stated, not
assumed. GATE: bitwise-exactness confirmed or delta documented.

### PHASE 5 - version bump + docs (the gate needs owner approval)

- project.janet: :version "0.1.1" -> "0.1.2" - ONLY AT THE END, and
  the bump itself is flagged for owner approval in the outcome
  (version-bump gate, rules.md).
- README.md: pin version text (v2.11.5 -> the new pin), the null-
  model line (now confirmed against the release carrying #934),
  the f32-seam read-side line if #934 resolved it.
- specs/api-contract.md: version header bump + a change line per
  the contract's own conventions.

## DELIVERABLES

- Updated install-rayforce.sh (pinned, drift-checked, same build
  discipline) + phase-0 delta table.
- Contract re-run results with per-cell diffs vs the v2.11.5
  baseline.
- Quint re-verification result.
- Parquet bitwise-exactness + precision spot-check results.
- cr13-fix-prompt-style outcome record:
  changes/pin-upgrade-outcome.md - built, verified, per-phase gate
  results, the delta table, redo commands, standing limitations.
- Commits on main as work lands (conventional commits, short).
  NO push (push gate). The version bump commit is the LAST commit
  and is flagged for owner approval in the outcome.

## PROCESS RULES (binding)

- REPL-first; evidence = files produced and re-run; harness
  grep/glob for discovery, sh-capture for commands only.
- PER-CELL FRESH PROCESSES for contract cells.
- 2-attempt ceiling per defect; escalate with the end-state
  sentence.
- The installed v2.11.5 engine at ~/.local/lib/rayforce is NOT
  to be deleted - the v3.0.1 build goes to a separate DEST until
  the owner ratifies the switch (the janet module's lib resolution
  order decides which loads; check modules/jennystats/rayforce.janet
  for the resolution path and state which engine your cells
  actually loaded - verify, do not assume).
- Stop conditions: ABI break requiring janet-side code changes
  (phase 0 gate), a contract cell that cannot be explained by the
  upstream changelog, third attempt on one defect -> STOP and
  report.

## CONTEXT

- Upstream: RayforceDB/rayforce. v2.11.5 is the current pin;
  v3.0.1 is the target (contains the janet-rayforce contributions
  #834 dict-error fix and the #934-adjacent dict work, plus the
  fixes that make the contract's null model current).
- The v2.11.5 install at ~/.local/lib/rayforce stays as the
  rollback path until the owner ratifies the switch.
- janet 1.42.1 FFI walls: skill gotchas 36-42 apply (:default is a
  calling convention; :size not :int; ffi/read needs a buffer).
