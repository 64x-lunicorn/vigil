defmodule Vigil.ScriptCallsTest do
  @moduledoc """
  The Elixir the deployment scripts send into the node, held to the application.

  `vigil_seed_token` in `scripts/lib.sh` mints through a `bin/vigil rpc`
  expression when the service is already running. That expression is an Elixir
  call written inside a shell string, and nothing compiles it: when
  `Vigil.OAuth.Token.issue_out_of_band` gained the persistence it writes
  through, every caller in `lib/` and `test/` moved with it and the rpc
  expression kept calling the arity that no longer existed. `init.sh` and
  `update.sh` both seed after the service is healthy, so both died there — and
  no check noticed, because `update_test.sh` stubs `vigil_seed_token` out and
  `release_smoke.sh` seeds through the standalone task.

  So this reads the scripts the way the compiler would have read the call: every
  `Vigil.*` remote call in `scripts/*.sh`, parsed as Elixir, must name a
  function the application exports at that arity.
  """
  use ExUnit.Case, async: true

  # The deployment scripts, not their tests: scripts/test/ drives them with
  # stand-ins and sends nothing into a node of its own.
  @scripts Path.wildcard(Path.expand("../../scripts/*.sh", __DIR__))

  # Where a call begins. The rest of it — its arguments, and whatever calls
  # they make — is left to the parser.
  @call_start ~r/Vigil(?:\.[A-Z]\w*)+\.[a-z_]\w*[?!]?\(/

  # Every `Vigil.*` call the scripts make, as {script, module, function, arity}.
  #
  # A call is read to the parenthesis that closes it, one line at a time: the
  # scripts write each expression on one line and escape its quotes for the
  # shell string around it. Unescaping those and handing the result to
  # `Code.string_to_quoted/1` gives the arity the node will be asked for —
  # counting commas would be fooled by the first argument that is itself a call.
  defp script_calls do
    for script <- @scripts,
        line <- script |> File.read!() |> String.split("\n"),
        [{start, _}] <- Regex.scan(@call_start, line, return: :index),
        call <- remote_calls(script, line |> binary_part(start, byte_size(line) - start)) do
      call
    end
    |> Enum.uniq()
  end

  defp remote_calls(script, text) do
    source = text |> String.replace(~S(\"), ~S(")) |> through_closing_paren()

    case Code.string_to_quoted(source) do
      {:ok, quoted} ->
        quoted
        |> Macro.prewalk([], fn
          {{:., _, [{:__aliases__, _, [:Vigil | _] = parts}, fun]}, _, args} = node, acc
          when is_atom(fun) and is_list(args) ->
            {node, [{Path.basename(script), Module.concat(parts), fun, length(args)} | acc]}

          node, acc ->
            {node, acc}
        end)
        |> elem(1)

      {:error, reason} ->
        flunk("""
        #{Path.basename(script)} calls into Vigil with an expression this check cannot read:

            #{source}

        #{inspect(reason)}

        A call no check reads is the one this file exists to prevent. Write it on
        one line, with its quotes escaped for the shell string it lives in.
        """)
    end
  end

  # The text up to and including the parenthesis that balances the first one,
  # skipping any inside a string literal.
  defp through_closing_paren(text), do: through_closing_paren(text, 0, 0, false)

  defp through_closing_paren(text, at, depth, in_string?) when at < byte_size(text) do
    case {binary_part(text, at, 1), in_string?} do
      {"\\", true} -> through_closing_paren(text, at + 2, depth, true)
      {"\"", _} -> through_closing_paren(text, at + 1, depth, not in_string?)
      {"(", false} -> through_closing_paren(text, at + 1, depth + 1, false)
      {")", false} when depth == 1 -> binary_part(text, 0, at + 1)
      {")", false} -> through_closing_paren(text, at + 1, depth - 1, false)
      _ -> through_closing_paren(text, at + 1, depth, in_string?)
    end
  end

  defp through_closing_paren(text, _at, _depth, _in_string?), do: text

  test "the scripts call into Vigil at all" do
    # Without this, a pattern that stopped matching would pass the check below
    # with nothing to check.
    assert script_calls() != [], """
    No `Vigil.*` call was found in scripts/*.sh.

    If the scripts no longer send Elixir into the node, this file has nothing
    left to guard and can go. If they still do, the pattern above has stopped
    seeing them.
    """
  end

  test "every Vigil call in the scripts names a function the application exports" do
    for {script, module, fun, arity} <- script_calls() do
      exported? = Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

      assert exported?, """
      #{script} calls #{inspect(module)}.#{fun}/#{arity}, and the application does not export it.

      The call lives in a shell string, so the compiler never saw it change.
      #{exported_arities(module, fun)}
      """
    end
  end

  defp exported_arities(module, fun) do
    if Code.ensure_loaded?(module) do
      case for {^fun, arity} <- module.__info__(:functions), do: arity do
        [] -> "#{inspect(module)} exports no #{fun} at any arity."
        arities -> "#{inspect(module)} exports #{fun} at arity #{Enum.join(arities, ", ")}."
      end
    else
      "#{inspect(module)} is not a module of the application."
    end
  end
end
