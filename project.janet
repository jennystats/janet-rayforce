# project.janet - jpm package manifest for janet-rayforce.
(declare-project
  :name "janet-rayforce"
  :description "The Rayforce columnar engine in the Janet process via core ffi - plan-plane ops, parquet reads, typed-contract handles"
  :license "AGPL-3.0"
  :version "0.1.2"
  :dependencies ["https://github.com/jennystats/janet-num"])

(declare-source
  :source ["jennystats"])
