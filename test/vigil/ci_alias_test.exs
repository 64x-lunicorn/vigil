defmodule Vigil.CiAliasTest do
  @moduledoc """
  `mix ci` and the workflow, held to each other.

  mix.exs says of the `ci` alias: *"Keep this list and .github/workflows/ci.yml
  in step: a check that only exists in CI is a check contributors discover too
  late."* That was a promise in a comment, and a comment cannot keep it — the
  two lists have to agree, and nothing noticed when they stopped.

  Both directions are checked, because each has its own failure — and they are
  checked at different strengths, on purpose.

  Alias → CI is compared on the whole command: a step the alias runs must
  appear in the workflow with at least those flags, because the flags *are* the
  check. `compile --warnings-as-errors --force` and `compile` are not the same
  question.

  CI → alias is compared on the task alone. The `static` job compiles before
  Credo and Dialyzer, which is a build step rather than a check, and demanding
  that the alias spell it the same way would be demanding that CI stop building
  the way it needs to. What this direction is for is narrower: no task may be
  reachable only by pushing.
  """
  use ExUnit.Case, async: true

  # Both workflows that run mix: a check hidden in the scheduled one is just as
  # unreachable from `mix ci` as one in the main gate.
  @workflows [
    Path.expand("../../.github/workflows/ci.yml", __DIR__),
    Path.expand("../../.github/workflows/audit.yml", __DIR__)
  ]

  # `mix deps.get` fetches, it does not check. CI needs it because a runner
  # starts with an empty deps/; a contributor already has one.
  @ci_only ~w(deps.get)

  defp alias_steps do
    Mix.Project.config()
    |> Keyword.fetch!(:aliases)
    |> Keyword.fetch!(:ci)
    # "cmd mix hex.audit" runs hex.audit in a separate OS process, for the
    # reason mix.exs gives. The command it names is the one to compare.
    |> Enum.map(&String.replace_prefix(&1, "cmd mix ", ""))
  end

  # Every `mix …` a workflow runs, whether it is a one-line `run:` or a line
  # inside a `run: |` block. Scanning only the one-line form left five blocks in
  # ci.yml invisible, so a check added inside one would have lapsed out of this
  # ratchet's reach without anything saying so.
  defp workflow_mix_commands do
    @workflows
    |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(?:run:\s+)?(?:if\s+)?(?:!\s+)?mix\s+(\S.*)$/, String.trim(line)) do
        [_, command] -> [command |> String.trim() |> strip_shell_noise()]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  # A command inside a block may be followed by a redirect or a continuation;
  # what this file compares is the task and its flags.
  #
  # The regex requires `mix` to begin the trimmed line, after an optional
  # `run:`, `if` or `!`. That is what separates a command from documentation:
  # the audit workflow echoes "### mix hex.audit" into its run summary and
  # names `mix deps.audit` inside an issue body, and neither is a check anybody
  # runs. The cost of the rule is that a `mix` in the middle of a `&&` chain
  # would go unseen; no workflow writes one, and a false command here would be
  # worse than a missed one — it would fail the build over a sentence.
  defp strip_shell_noise(command) do
    command
    |> String.split(~r/\s*(?:\d*[<>]|[|&;])|\s*\\$/, parts: 2)
    |> hd()
    |> String.trim()
    |> String.trim_trailing("\"")
  end

  test "every step of the ci alias is one CI actually runs" do
    commands = workflow_mix_commands()

    for step <- alias_steps() do
      covered? = Enum.any?(commands, &(&1 == step or String.starts_with?(&1, step <> " ")))

      assert covered?, """
      `mix ci` runs "mix #{step}", and .github/workflows/ci.yml does not.

      A check that only exists in the alias is a check CI does not enforce.
      Add it to the workflow, or drop it from the alias.

      The workflows run: #{Enum.map_join(commands, "\n                    ", &("mix " <> &1))}
      """
    end
  end

  test "every mix command CI runs is one the ci alias runs" do
    steps = alias_steps()

    tasks = Enum.map(steps, &(&1 |> String.split(" ") |> hd()))

    for command <- workflow_mix_commands(),
        task = command |> String.split(" ") |> hd(),
        task not in @ci_only do
      covered? = task in tasks

      assert covered?, """
      CI runs "mix #{command}", and `mix ci` does not.

      That is the check a contributor discovers after pushing rather than
      before. Add the task to the ci alias in mix.exs, or add it to @ci_only
      here with the reason it is not a check.

      mix ci runs: #{Enum.map_join(steps, "\n              ", &("mix " <> &1))}
      """
    end
  end
end
