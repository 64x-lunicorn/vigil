#!/usr/bin/env bash
# scripts/test/harness.sh — the counting and the reporting, for the shell suites.
#
# Sourced by verify_test.sh, update_test.sh and release_smoke.sh; it has no
# execution path of its own. What it owns is what all three had a copy of: an
# assertion that counts, an assertion that compares, a heading, and the summary
# that decides what the run exits with. What it deliberately does not own is a
# subject or a stand-in — each suite still builds its own world and keeps it.
#
# Three copies is three statements of one rule — what a pass prints, what a
# failure prints, what a green run exits with — kept in step across three files
# by hand. Stated once here, a suite ends on `report` and `report` is what
# turns the counters into an exit code.
#
# #156 was a defect of that kind and not of this code: an assertion in
# verify_test.sh recorded a `fail` and an unconditional `pass` for the same
# check, so its count and its verdict disagreed. That sat in the suite's own
# loop rather than in the copied helpers, and none of the three could exit 0
# on a red count. What was missing was somewhere to say once what counting is
# for.
#
# `fail` increments last on purpose. Its message line is a test for $2, false
# whenever a failure carries no detail, and a function whose last command is
# false returns 1 — which under `set -e` would end the run at the first
# undetailed failure instead of reporting all of them. The increment keeps that
# off the function's exit status.

PASS=0
FAIL=0

# A passing assertion goes to stdout and a failing one to stderr, so a log
# filtered to stderr is the failures and nothing else.
pass() {
  echo "  ok   - $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL - $1" >&2
  [ -n "${2:-}" ] && echo "         $2" >&2
  FAIL=$((FAIL + 1))
}

# `assert_eq <description> <expected> <actual>` — the comparison the delivery
# suites make most. Here so that a mismatch reads the same in all of them.
assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

# A heading between groups of assertions. All three suites number theirs
# ("3/7", "12/12"), so a log that stops early says how far the run got.
section() {
  echo
  echo "── $1 ──"
}

# The verdict, and the last thing a suite runs.
#
# Named `report` rather than `summary` because scripts/lib.sh already has a
# `summary` and verify_test.sh sources both: lib.sh's runs from an EXIT trap
# and describes the run of a deployment script, which is a different thing and
# keeps its name.
report() {
  echo
  echo "──────────────────────────────────────────"
  echo "  passed: ${PASS}    failed: ${FAIL}"
  echo "──────────────────────────────────────────"

  [ "$FAIL" -eq 0 ]
}
