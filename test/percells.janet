# percells.janet - per-expression instrumentation for the rayforce smoke
# file, preserving its own execution model (one process, ordered shared
# defs). Owner ruling 2026-10-26: the file is a sequential script whose
# v2.11.5 known-green baseline was established by running it exactly so;
# the faithful instrument keeps that order and judges each top-level
# expression individually. Both engines run under the SAME instrument, so
# instrument-induced state appears symmetrically and cancels in the diff.
#
# Usage: janet percells.janet <smoke-file> <out-file>
#
# Only NON-definition top-level forms are probes; definitions are replayed
# as-is in order (they are the setup, not the assertions). A def that
# throws aborts the sweep and is reported as the failing cell.

(def smoke (get (dyn *args*) 1))
(def out-file (get (dyn *args*) 2))

(def forms (parse-all (slurp smoke)))

# Definitions are setup: replay them, do not judge them.
(defn definition? [f]
  (and (indexed? f)
       (let [h (f 0)]
         (or (= h 'def) (= h 'defn) (= h 'defn/typed) (= h 'defmacro)
             (= h 'var) (= h 'def-)))))
# ...except a def whose value is a form we want judged is still setup; the
# assertions in this file are bare top-level calls, so the split is clean.

(def results @[])
(var idx 0)
(var aborted false)
(var abort-msg "")

# err->string keeps one line per failure for the report
(defn oneline [e] (string/replace-all "\n" " | " (string e)))

(each f forms
  (when (not aborted)
    (def is-def (definition? f))
    (def text (string/format "%q" f))
    (def desc (string/slice text 0 (min 70 (length text))))
    (def r (try
             (do (eval f) {:status "PASS" :err ""})
             ([e] {:status "FAIL" :err (oneline e)})))
    (when (not is-def)
      (array/push results {:idx idx :kind "expr" :label desc
                           :status (r :status) :err (r :err)})
      (set idx (+ idx 1))
      # A failing assertion does not abort: later cells are independent
      # top-level forms. A COMPILE-class error would desync the def
      # replay for everything after it, so that one aborts the sweep.
      (when (= (r :status) "FAIL")
        (def msg (r :err))
        (when (or (string/find "compile error" msg) (string/find "unknown symbol" msg))
          (set aborted true)
          (set abort-msg msg))))
    (when (and is-def (= (r :status) "FAIL"))
      (set aborted true)
      (set abort-msg (string "definition failed: " (r :err)))
      (array/push results {:idx idx :kind "def" :label desc
                           :status "FAIL" :err (r :err)}))))

(import jennystats/json)
(spit out-file (json/encode {:aborted aborted :abort-msg abort-msg :results results}))
(printf "probes=%d pass=%d fail=%d%s -> %s"
        (length results)
        (length (filter |(= ($ :status) "PASS") results))
        (length (filter |(= ($ :status) "FAIL") results))
        (if aborted (string " ABORTED: " abort-msg) "")
        out-file)
