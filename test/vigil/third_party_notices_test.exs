defmodule Vigil.ThirdPartyNoticesTest do
  @moduledoc """
  THIRD_PARTY_NOTICES.md names every locked Hex package at its locked version.

  The file travels inside every release tarball as the attribution inventory,
  and it is written by hand while mix.lock is written by Mix and by Dependabot
  — so it lagged a `tz` bump without anything noticing. Each row's link and
  version column are held to mix.lock here, both ways: a locked package the
  file does not list, a version that differs, and a row for a package that is
  no longer locked all fail, and CI runs this with the rest of the suite.
  Licenses are not compared: Hex metadata is not in the lock, and the file
  says when they were last checked.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # `| [name](https://hex.pm/packages/name/1.2.3) | 1.2.3 | License |`
  @row ~r{^\| \[([a-z0-9_]+)\]\(https://hex\.pm/packages/([a-z0-9_]+)/([^)\s]+)\) \| ([^|\s]+) \|}m

  defp locked do
    {lock, _binding} = Code.eval_file(Path.join(@root, "mix.lock"))

    for {name, {:hex, _package, version, _hash, _managers, _deps, _repo, _outer}} <- lock,
        into: %{},
        do: {to_string(name), version}
  end

  defp listed do
    Path.join(@root, "THIRD_PARTY_NOTICES.md")
    |> File.read!()
    |> then(&Regex.scan(@row, &1, capture: :all_but_first))
  end

  test "every row's link and version column say the same" do
    rows = listed()
    assert rows != [], "no dependency rows found in THIRD_PARTY_NOTICES.md"

    for [name, linked_name, linked_version, version] <- rows do
      assert linked_name == name, "#{name}'s row links to #{linked_name}"
      assert linked_version == version, "#{name}'s row links #{linked_version}, says #{version}"
    end
  end

  test "the notices list exactly the locked packages, at their locked versions" do
    listed = Map.new(listed(), fn [name, _, _, version] -> {name, version} end)

    assert listed == locked(), """
    THIRD_PARTY_NOTICES.md does not match mix.lock.
      locked, not listed or at another version: #{inspect(Map.to_list(locked()) -- Map.to_list(listed))}
      listed, not locked or at another version: #{inspect(Map.to_list(listed) -- Map.to_list(locked()))}
    """
  end
end
