# Dialyzer findings that are known, understood and deliberately not fixed here.
#
# This list is a ratchet, not a dumping ground:
#
#   * Every entry names *why* it is safe. An entry without a reason is a bug
#     waiting to be rediscovered.
#   * `list_unused_filters: true` in mix.exs makes Dialyzer fail when an entry
#     here stops matching, so a fixed finding cannot quietly leave a stale
#     filter behind.
#   * Any finding NOT listed here fails CI.
[
  # `:binary.matches/2` always returns a list — unlike `:binary.match/2`, it
  # never returns `:nomatch`. The branch is dead defensive code, not a
  # behavioural bug: the live branch returns `length([]) == 0` for "no match",
  # which is the same answer. Harmless to keep, worth removing in a cleanup PR.
  {"lib/vigil/search.ex", :pattern_match}
]
