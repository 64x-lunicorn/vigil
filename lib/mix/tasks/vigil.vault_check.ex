defmodule Mix.Tasks.Vigil.VaultCheck do
  @shortdoc "Read-only vault adoption check (vault doctor)"
  @moduledoc """
  Runs the report-only vault checks against a vault and prints the result as
  JSON on stdout. Called by `scripts/init.sh` (adoption phase and
  `--check-only`) and processed there with `jq`. Read-only: no `Vigil.Store`,
  no `git pull`, no writes (see `Vigil.VaultCheck`).

      mix vigil.vault_check /path/to/vault

  Exit 0 on a successful run — findings live in the JSON, not in the exit
  code; interpreting them is the caller's job. Exit 2 when the path is not a
  readable directory, matching `init.sh --check-only`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    # Vigil.Parser logs warnings while parsing (missing frontmatter and the
    # like). They are deliberately irrelevant here — Vigil.VaultCheck reports
    # the same cases in structured form — and would otherwise pollute the JSON
    # on stdout.
    #
    # Erlang's :logger rather than Logger.configure(level: :none): both set the
    # same primary level, but :none is missing from Elixir's own
    # `configure_opts()` typespec in some versions, so the Elixir call makes
    # Dialyzer report a broken contract here and cascade it into no_return for
    # run/1. Same effect, no spec gap, nothing to add to .dialyzer_ignore.exs.
    :logger.set_primary_config(:level, :none)

    case args do
      [vault_path] -> check(Path.expand(vault_path))
      _ -> Mix.raise("Usage: mix vigil.vault_check <vault-path>")
    end
  end

  defp check(vault_path) do
    unless File.dir?(vault_path) do
      IO.puts(:stderr, "Not a directory: #{vault_path}")
      System.halt(2)
    end

    report = Vigil.VaultCheck.run(vault_path)
    IO.puts(Jason.encode!(report))
  end
end
