defmodule Vigil.Release do
  @moduledoc """
  What an operator script asks a built release with `bin/vigil eval`, where
  no Mix task exists: a release carries the application, not its tooling.

  `update.sh` asks the release it is about to replace for its chunk ids and
  hands the list to `mix vigil.slug_diff --against` in the target checkout,
  so the two builds are compared on the same vault (docs/compatibility.md,
  "The vault conventions"). The node is not started: `eval` loads the code
  and runs one expression.
  """

  require Logger

  alias Vigil.Vault.{Layout, Rules}

  @doc """
  Prints every chunk id of the vault at `VIGIL_VAULT_PATH`, one per line and
  sorted, walked with the exclusions `VIGIL_EXCLUDE` names.

  Both are read from the environment the script hands the command rather
  than from application configuration, so the answer does not depend on
  whether `eval` evaluated `config/runtime.exs`. Nothing else is printed:
  the output is the list. `VIGIL_EXCLUDE` is read as
  `config/runtime.exs` reads it: comma-separated, trimmed, blanks dropped.
  """
  @spec chunk_ids() :: :ok
  def chunk_ids do
    # The parser warns about a note without frontmatter, and under `eval` a
    # warning is printed to the same stdout as the ids.
    Logger.put_process_level(self(), :none)
    Vigil.Stdio.utf8()

    vault_path = System.fetch_env!("VIGIL_VAULT_PATH")

    exclude =
      System.get_env("VIGIL_EXCLUDE", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    files = vault_path |> Layout.over_vault!(exclude) |> Layout.note_paths()

    vault_path
    |> Rules.chunk_ids(files)
    |> Enum.each(&IO.puts/1)
  end
end
