# Credo configuration — used by `mix credo --strict`, which runs in `mix ci`
# and in .github/workflows/ci.yml.
#
# Two rules shaped this file:
#
#   1. The gate enforces checks that catch *mistakes* (unused results, dead
#      code, leftover IO.inspect, unsafe conversions). Purely stylistic checks
#      that would demand a repo-wide reformat are off — a gate nobody can make
#      green on day one gets bypassed instead of respected. Everything not
#      listed under `disabled` below stays at Credo's default.
#
#   2. Size and complexity limits are a ratchet, not an aspiration. Each
#      threshold below is pinned to the worst value in the codebase today, so
#      existing code passes but nothing is allowed to get *worse*. Lower a
#      number whenever a refactor makes room for it.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/test/fixtures/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        # `extra` overrides parameters while keeping every other default check
        # enabled. (`enabled` would *replace* the default set — silently
        # turning off ~50 checks, which is the opposite of a gate.)
        extra: [
          # ── Ratcheted thresholds (see rule 2 above) ──────────────────────
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 8]},

          # Mix tasks legitimately branch on Mix.env at runtime.
          {Credo.Check.Warning.MixEnv, [excluded_paths: ["lib/mix/tasks/"]]}
        ],
        disabled: [
          # Stylistic only — flagged across most of lib/ today. Turning any of
          # these on is a deliberate cleanup PR, not a surprise CI failure.
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.IoPuts, []}
        ]
      }
    }
  ]
}
