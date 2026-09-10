defmodule Vigil.Vault.AbsentFacts do
  @moduledoc """
  A `Vigil.Vault.Facts` whose every question answers "nothing there".

  The counterpart to `Vigil.Vault.Facts.over_vault/3`, for tests that decide a
  policy with no vault behind it. It is a separate name on purpose:
  every one of these answers sits on the permissive side of the gate it feeds,
  so a test that wants an absent fact has to say so — `Vigil.Vault.Facts`
  itself supplies no defaults.

  `overrides` replaces any of them, and is the only way a test states a fact
  the policy is meant to find.
  """

  alias Vigil.Vault.{Facts, Layout}

  @doc """
  A layout for a vault that is not on disk: the domains, exclusions and
  project directories a test wants the policy to see, over a vault path
  nothing reads.
  """
  @spec layout(Enumerable.t()) :: Layout.t()
  def layout(fields \\ []) do
    Layout.new(
      Keyword.merge(
        [vault_path: "/nonexistent", domains: [], exclude: [], project_dirs: []],
        Enum.to_list(fields)
      )
    )
  end

  @doc "A `Facts` answering nothing, with `overrides` applied on top."
  @spec answering_nothing(Enumerable.t()) :: Facts.t()
  def answering_nothing(overrides \\ []) do
    Facts.new(
      Keyword.merge(
        [
          layout: layout(),
          naming: %{},
          today: ~D[1970-01-01],
          path_exists?: fn _path -> false end,
          read_note: fn _path -> :error end,
          find_similar: fn _query, _domain, _depth -> [] end,
          count_headings: fn _path -> 0 end,
          find_backlinks: fn _path -> [] end,
          find_chunk: fn _id -> nil end,
          find_section: fn _path, _heading -> nil end
        ],
        Enum.to_list(overrides)
      )
    )
  end
end
