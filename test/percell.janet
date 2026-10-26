# percell.janet - split the rayforce smoke file into its banner-delimited
# cells and run each in a FRESH process, so a cell's verdict cannot be
# polluted by state left by the previous cell (skill gotcha 34).
#
# Usage: janet percell.janet <smoke-file> <out-json>
# Env:   RAYFORCE_LIB selects the engine under test (unset = pinned default)
#
# Each cell = the forms between two "#==...==#" banner blocks. A banner
# block is three consecutive comment lines; the middle line is the title.
# The prologue (imports + assert helpers, everything before the first
# banner) is prepended to every cell so each cell is self-contained.

(import jennystats/kit :prefix "")

(def smoke (get (dyn *args*) 1))
(def out-json (get (dyn *args*) 2))

(def text (string (slurp smoke)))
(def lines (string/split "\n" text))

(defn banner-line? [l] (and (string/has-prefix? "#==" l) (string/has-suffix? "==#" l)))

# A section starts at a banner line; its title is the next line and the
# banner pair may be separated by further prose lines (the ownership
# section has several), so find the NEXT banner rather than assuming a
# triple. Header prose that merely mentions the banner shape is ignored
# because a banner line alone carries no title.
(def sections @[])
(var i 0)
(var pending nil)
(while (< i (length lines))
  (def l (lines i))
  (cond
    (banner-line? l)
      (if (nil? pending)
        (set pending i)                                   # section opener
        (do (def title (string/trim (lines (+ pending 1))))
            (array/push sections {:start pending :title title
                                  :body-from (+ i 1) :title-line (+ pending 1)})
            (set pending nil)))
    nil)
  (++ i))

# prologue = everything before the first section opener
(def first-start (if (empty? sections) 0 (get (sections 0) :start)))
(def prologue (string/join (slice lines 0 first-start) "\n"))

# cells: body runs from a section's closing banner to the next opener
(def cells @[])
(eachp [idx s] sections
  (def body-end (if (< (inc idx) (length sections))
                  (get (sections (inc idx)) :start)
                  (length lines)))
  (def body (string/join (slice lines (get s :body-from) body-end) "\n"))
  (array/push cells {:name (get s :title) :body body}))
(def tmpdir (string "/tmp/percell-" (gensym)))
(os/mkdir tmpdir)
(def smoke-dir (string (string/slice smoke 0 (last (string/find-all "/" smoke)))))

(def results @[])
(eachp [idx c] cells
  (def fname (string tmpdir "/cell-" idx ".janet"))
  (spit fname (string prologue "\n" (get c :body) "\n(print \"__CELL_OK__\")\n"))
  # fresh process per cell; output to a file so a crash's exit status is not
  # masked by a pipeline (skill gotcha 40)
  (def logf (string tmpdir "/cell-" idx ".log"))
  (def rc (os/execute ["/bin/sh" "-c"
                       (string "cd " (sh-quote smoke-dir) " && "
                               "JANET_PATH=\"$(dirname " (sh-quote smoke) "):$HOME/.local/lib/janet\" "
                               "janet " (sh-quote fname) " > " (sh-quote logf) " 2>&1")]
                      :p))
  (def out (try (string (slurp logf)) ([_] "")))
  (def ok (and (= rc 0) (not (nil? (string/find "__CELL_OK__" out)))))
  (def err (if ok ""
             (let [ls (filter |(not (string/has-prefix? "__CELL_OK__" $))
                              (filter |(not (empty? $)) (string/split "\n" out)))]
               (if (empty? ls) (string "rc=" rc " (no output)") (string (last ls))))))
  (array/push results {:idx idx :name (get c :name) :status (if ok "PASS" "FAIL") :rc rc :err err})
  (def nm (get c :name))
  (printf "%-58s %s" (string/slice nm 0 (min 58 (length nm))) (if ok "PASS" "FAIL")))

(os/execute ["/bin/rm" "-rf" tmpdir])
(defn brief [r]
  (struct :idx (r :idx) :name (r :name) :status (r :status)
          :rc (r :rc) :err (r :err)))
(spit out-json (string/format "%q" (map brief results)))
(printf "\ncells=%d pass=%d fail=%d -> %s"
        (length results)
        (length (filter |(= ($ :status) "PASS") results))
        (length (filter |(= ($ :status) "FAIL") results))
        out-json)
