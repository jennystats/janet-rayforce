# phase4-check.janet - Phase 4 of the pin upgrade: parquet bitwise-exactness
# and a numeric precision spot-check, run against whichever engine
# $RAYFORCE_LIB / the pinned default resolves.
#
# Bitwise-exactness is asserted on RAW IEEE-754 BIT PATTERNS, not on
# numeric ==, so a one-ulp drift cannot hide behind a tolerant compare.
# Usage: janet phase4-check.janet <out-file>

(import jennystats/rayforce :as rf)

(def out-file (get (dyn *args*) 1))
(def DIR (or (get (os/environ) "RAYFORCE_FIXTURES") "test/fixtures/rayforce"))

(defn bits
  "IEEE-754 binary64 bit pattern of x as a 16-char hex string. A string,
  not a number: the u64 abstract does not survive JSON (skill gotcha 39)
  and the pattern exceeds the 2^53 plain-double band (gotcha 26)."
  [x]
  (string/format "%016x" (ffi/read :uint64 (ffi/write @[:double 1] @[x]))))

(def fails @[])
(defn check [what ok detail]
  (when (not ok) (array/push fails (string what ": " detail))))

(def report @{})

# --- engine identity ---------------------------------------------------
(def version (string/join (map string (rf/engine-version)) "."))
(put report :version version)
(put report :lib (or (get (os/environ) "RAYFORCE_LIB") "pinned-default"))

# --- 1. f64 parquet bitwise -------------------------------------------
# Source values the fixture was written from (smoke-rayforce c2).
(def f64-src @[0.1 3.25 3.5 -0.0 1e300])
(def f64-batches (rf/parquet-rows (string DIR "/f64.parquet")))
(def f64-cols (rf/table-columns (first f64-batches)))
(def f64-got (f64-cols "v"))
(def f64-want-bits (map bits @[0.1 3.25 3.5 0.0 1e300]))
(def f64-got-bits (map bits f64-got))
(each h f64-batches (:close h))
(check "f64 parquet bitwise" (deep= f64-want-bits f64-got-bits)
       (string "want " (string/format "%q" f64-want-bits) " got " (string/format "%q" f64-got-bits)))
(put report :f64-bits f64-got-bits)

# --- 2. i64 parquet exactness (typed lane, 2^53 band) ------------------
(def i64-batches (rf/parquet-rows (string DIR "/i64.parquet")))
(def i64-cols (rf/table-columns (first i64-batches)))
(def i64-got (i64-cols "big"))
(def i64-want @[1099511627776 -9007199254740991 42 0])
(each h i64-batches (:close h))
(check "i64 parquet exact" (deep= i64-want i64-got)
       (string "want " (string/format "%q" i64-want) " got " (string/format "%q" i64-got)))
(put report :i64 i64-got)

# --- 3. precision spot-check: F64 in-memory round-trip, bitwise --------
# Values chosen to expose fast-math or reassociation: a non-representable
# decimal, a negative zero, a denormal-ish value, and a large magnitude.
(def prec-src @[0.1 0.2 0.30000000000000004 -0.0 1e300 -1e-320
                 2.2250738585072014e-308 1.7976931348623157e308])
(def t (rf/table-from-columns @{:v prec-src}))
(def prec-got (rf/table-column t "v"))
(:close t)
(def prec-want-bits (map bits prec-src))
(def prec-got-bits (map bits prec-got))
(check "f64 in-memory round-trip bitwise" (deep= prec-want-bits prec-got-bits)
       (string "want " (string/format "%q" prec-want-bits) " got " (string/format "%q" prec-got-bits)))
(put report :prec-bits prec-got-bits)

# --- 4. arithmetic spot-check: 0.1+0.2 must be the IEEE result ----------
# The canonical fast-math tripwire: an engine built with -ffast-math or
# reassociation can fold this to exactly 0.3.
(def sum (+ 0.1 0.2))
(def want-sum 0.30000000000000004)
(check "0.1+0.2 bitwise" (= (bits sum) (bits want-sum))
       (string "want bits " (bits want-sum) " got " (bits sum)))
(put report :sum-bits (bits sum))

# --- 5. a computed F64 column keeps full precision ----------------------
(def t2 (rf/table-from-columns @{:a @[0.1 1e300] :b @[0.2 1e300]}))
(def col-a (rf/table-column t2 "a"))
(def col-b (rf/table-column t2 "b"))
(:close t2)
(defn add2 [x y] (+ x y))
(def summed (map add2 col-a col-b))
(check "column arithmetic 0.1+0.2 bitwise" (= (bits (summed 0)) (bits want-sum))
       (string "want bits " (bits want-sum) " got " (bits (summed 0))))
(put report :col-sum-bits (bits (summed 0)))

(put report :fails fails)
(put report :status (if (empty? fails) "PASS" "FAIL"))
(import jennystats/json)
(spit out-file (json/encode report))
(printf "engine %s (%s): %s, %d fail(s) -> %s"
        version (report :lib) (report :status) (length fails) out-file)
(each f fails (print "  FAIL " f))
