defmodule Vigil.Stdio do
  @moduledoc """
  Standard output for what a script reads: `mix vigil.vault_check`,
  `mix vigil.slug_diff`, `bin/vigil eval 'Vigil.Release.chunk_ids()'` and
  `scripts/grants.sh`.

  The VM takes the encoding of standard_io from the locale, and with no
  UTF-8 locale (`LANG` unset, as under root, cron or a bare `ssh` command)
  it is latin1. A path such as `home/café.md` then comes out as latin1 bytes,
  and an em dash as the text `\\x{2014}`: `jq` refuses the JSON, and a chunk
  id list no longer matches the one taken under a UTF-8 locale. vigil's
  output is UTF-8 whatever the locale says.
  """

  @doc """
  Sets standard_io — the caller's group leader — to UTF-8. A device that
  cannot take the option (it is gone, or not an io server) is left as it is:
  the output is then what it would have been without this call.
  """
  @spec utf8() :: :ok
  def utf8 do
    _ = :io.setopts(:standard_io, encoding: :unicode)
    :ok
  end
end
