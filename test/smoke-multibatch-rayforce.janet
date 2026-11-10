# multibatch-smoke.janet - multi-batch parquet cells against the published
# module: the reader caps a batch at 65,536 rows, a larger file arrives as
# several table handles, and the internal batch-merge helper rejoins them in
# one engine-side pass. Run: strict test/smoke-multibatch-rayforce.janet
# (requires librayforce.so + the janet-num kernel; the fixtures come from
# $RAYFORCE_MULTIBATCH_FIXTURES or test/fixtures/multibatch/).
#
# End-to-end rayforce-query integration coverage lives in the janet-query
# repository, not this suite.
(import jennystats/typed :prefix "")
(import jennystats/rayforce :as rf)

(def cur (dyn :current-file))
(def DIR (string (or (get (os/environ) "RAYFORCE_MULTIBATCH_FIXTURES")
                     (string (string/slice cur 0 (last (string/find-all "/" cur)))
                             "/fixtures/multibatch"))))

(defn assert-eq [a b msg]
  (unless (deep= a b)
    (errorf "assert %s: expected %q, got %q" msg a b)))

# -- 65,537 rows: the first row past the batch cap ---------------------------
(def p537 (string DIR "/mb-65537.parquet"))
(def b537 (rf/parquet-rows p537))
(assert-eq 2 (length b537) "cell c: 65,537 rows is two reader batches")
(assert-eq 65536 (rf/table-nrows (b537 0)) "cell c: batch 0 rows")
(assert-eq 1 (rf/table-nrows (b537 1)) "cell c: batch 1 rows")
(each h b537 (:close h))

# -- 100,000 rows: two batches (65,536 + 34,464) ----------------------------
(def p100 (string DIR "/mb-100000.parquet"))
(def batches (rf/parquet-rows p100))
(assert-eq 2 (length batches) "cell a: 100,000 rows is two reader batches")
(assert-eq 65536 (rf/table-nrows (batches 0)) "cell a: batch 0 rows")
(assert-eq 34464 (rf/table-nrows (batches 1)) "cell a: batch 1 rows")

# -- the merge helper: row count, both column classes, the boundary row ------
(def merged (rf/-concat-batches batches))
(assert-eq 100000 (rf/table-nrows merged) "cell h: helper row count")
(assert-eq 8 (rf/table-ncols merged) "cell h: helper column count")
(def country (rf/table-column merged "country"))
(assert-eq 100000 (length country) "cell d: STR column spans every row")
(assert-eq (get (rf/table-column (batches 1) "country") 0) (country 65536)
           "cell d: STR boundary element is the first row of batch 1")
(assert-eq (get (rf/table-column (batches 0) "invoiceid") 65535)
           (get (rf/table-column merged "invoiceid") 65535)
           "cell h: numeric boundary element is the last row of batch 0")
(def invoice (rf/table-column merged "invoiceid"))
(assert-eq 1 (invoice 0) "cell a: first row is invoiceid 1")
(assert-eq 100000 (invoice 99999) "cell a: last row is invoiceid 100,000")

# -- the input handles stay caller-owned and open after the merge -----------
(assert-eq 65536 (rf/table-nrows (batches 0)) "cell h: batch 0 still open")
(:close merged)
(each h batches (:close h))

# -- refusal: an empty batch array raises the module class ------------------
(def empty-batches @[])
(def e (try (string (rf/-concat-batches empty-batches)) ([err] (string err))))
(unless (string/find "rayforce: -concat-batches: expected a non-empty array" e)
  (errorf "assert cell h: empty input refused: %q" e))

(print "multibatch smoke ok")
