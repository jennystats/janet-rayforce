# project.janet - jpm package manifest for janet-rayforce.
# Dependency URLs follow the janet-lang/pkgs registry convention
# (GitHub); the CI forge-maps jennystats URLs to the GitLab mirrors.
(declare-project
  :name "janet-rayforce"
  :description "The Rayforce columnar engine in the Janet process via core ffi - plan-plane ops, parquet reads, typed-contract handles"
  :license "AGPL-3.0"
  :version "0.1.5"
  :dependencies ["https://github.com/jennystats/janet-kit"
                 "https://github.com/jennystats/janet-num"])

(declare-source
  :source ["jennystats"])
