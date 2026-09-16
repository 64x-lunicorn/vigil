defmodule Vigil.DocReferencesTest do
  @moduledoc """
  What the documents name, held to what the code has.

  `docs/README.md` says it outright: *"Where a document and the code disagree,
  the code is right and the document is a bug."* The documents name functions
  by module and arity and tell a contributor which tests to run, and nothing
  compiles either. `docs/oauth.md` went on naming `Vigil.OAuth.Token.issue_pair/2`
  after it became `/3`, and `CONTRIBUTING.md` told contributors to run a
  `search_test.exs` that no longer existed — a command that failed as written,
  and a reference a reader could not follow.

  So this reads them the way a reader would follow them, in the two shapes that
  are unambiguous: a fully qualified `Vigil.*` function with an arity must be
  one the application exports at that arity, and every path a `mix test`
  command names must exist.

  Bare `function/arity` references are left alone: which module one means is
  the sentence's to say, not a pattern's. `docs/history.md` is left out on
  purpose — it records what the code *was*.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @documents Enum.reject(
               Path.wildcard(Path.join(@root, "docs/**/*.md")) ++
                 Enum.map(~w(README.md CONTRIBUTING.md SECURITY.md), &Path.join(@root, &1)),
               &(Path.basename(&1) == "history.md")
             )

  @reference ~r/`(Vigil(?:\.[A-Z]\w*)+)\.([a-z_]\w*[?!]?)\/(\d+)`/

  # `mix test` and what follows it on the line, up to a closing backtick. Only
  # the words shaped like a path are checked, so a sentence that goes on after
  # the command is not read as one; a `path:line` suffix is dropped first.
  @mix_test ~r/\bmix test((?: +[^\s`]+)+)/

  defp relative(path), do: Path.relative_to(path, @root)

  defp references do
    for document <- @documents,
        [_, module, fun, arity] <- Regex.scan(@reference, File.read!(document)) do
      {relative(document), Module.concat([module]), String.to_atom(fun), String.to_integer(arity)}
    end
    |> Enum.uniq()
  end

  defp test_paths do
    for document <- @documents,
        [_, args] <- Regex.scan(@mix_test, File.read!(document)),
        arg <- String.split(args),
        String.contains?(arg, "/"),
        do: {relative(document), arg |> String.split(":") |> hd()}
  end

  test "the documents name Vigil functions at all" do
    # Without this, a pattern that stopped matching would pass the check below
    # with nothing to check.
    assert references() != []
    assert test_paths() != []
  end

  test "every Vigil.Module.function/arity a document names is exported at that arity" do
    for {document, module, fun, arity} <- references() do
      exported? =
        Code.ensure_loaded?(module) and
          (function_exported?(module, fun, arity) or macro_exported?(module, fun, arity))

      assert exported?, """
      #{document} names #{inspect(module)}.#{fun}/#{arity}, and the application does not export it.

      #{exported_arities(module, fun)}
      Fix the document: the code is the authority.
      """
    end
  end

  test "every path a documented `mix test` command names exists" do
    for {document, path} <- test_paths() do
      assert File.exists?(Path.join(@root, path)), """
      #{document} tells the reader to run `mix test #{path}`, and #{path} does not exist.
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
