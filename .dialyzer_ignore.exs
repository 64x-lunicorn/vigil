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
  {"lib/vigil/search.ex", :pattern_match},

  # `Logger.configure(level: :none)` is valid and documented at runtime
  # (verified: it returns :ok and `Logger.level()` reports `:none` afterwards),
  # but `:none` is missing from Elixir's own `configure_opts()` typespec.
  # Dialyzer therefore calls the contract broken and cascades that into
  # `no_return` for run/1 and `unused_fun` for check/1. Upstream spec gap.
  {"lib/mix/tasks/vigil.vault_check.ex", :call},
  {"lib/mix/tasks/vigil.vault_check.ex", :no_return},
  {"lib/mix/tasks/vigil.vault_check.ex", :unused_fun}
]
