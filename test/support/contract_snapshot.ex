defmodule Vigil.ContractSnapshot do
  @moduledoc """
  Records a published interface as a file, so that changing it is an edit
  somebody has to make on purpose.

  The documents this guards — the MCP tool list, the two OAuth metadata
  documents — are contracts with software that is already connected. A renamed
  parameter, a reordered enum, a dropped field: each is a one-line change here
  and a broken client out there, and none of them fails a test that asserts
  field by field, because such a test only knows about the fields somebody
  thought to name in it.

  So the whole document is rendered canonically and compared byte for byte
  against `test/fixtures/contracts/<name>.json`. The recorded file is the
  contract; the diff in a pull request is the review of it. Accepting a change
  is deliberate:

      UPDATE_CONTRACTS=1 mix test test/vigil/contracts_test.exs

  Canonically means: keys sorted at every level, two-space indent, one trailing
  newline. Map key order in Elixir is an implementation detail of the term, and
  a snapshot that moves when nothing moved gets regenerated without being read.
  List order is preserved — the tool list's order is part of what the client is
  handed, not an artefact of how it is stored.
  """
  import ExUnit.Assertions

  @dir "test/fixtures/contracts"

  @doc """
  Asserts `document` still renders to what `name`'s recorded contract holds.

  Writes the file instead of asserting when `UPDATE_CONTRACTS=1` is set.
  """
  @spec assert_unchanged(String.t(), term()) :: :ok
  def assert_unchanged(name, document) do
    path = Path.join(@dir, name <> ".json")
    rendered = canonical(document)

    cond do
      update?() ->
        File.mkdir_p!(@dir)
        File.write!(path, rendered)
        :ok

      not File.exists?(path) ->
        flunk("""
        No recorded contract at #{path}.

        Record it, read the file, and commit it with the change that produced it:

            UPDATE_CONTRACTS=1 mix test test/vigil/contracts_test.exs
        """)

      true ->
        compare(path, rendered)
    end
  end

  # The comparison renders its own diff. ExUnit's would be a pair of 11 KB
  # escaped strings, truncated in the middle — a failure nobody reads is a
  # failure that gets regenerated unread, which is the one outcome this file
  # exists to prevent. A line diff of a canonically rendered document names
  # the changed field and nothing else.
  defp compare(path, rendered) do
    recorded = File.read!(path)

    if rendered == recorded do
      :ok
    else
      actual = path <> ".actual"
      File.write!(actual, rendered)

      flunk("""
      A published interface changed: #{path} no longer describes what this
      build serves. Every client already connected sees the difference.

      #{diff(recorded, rendered)}
      - recorded contract   #{path}
      + this build serves   #{actual}

      If the change is intended, record it and commit the diff alongside the
      change that produced it:

          UPDATE_CONTRACTS=1 mix test test/vigil/contracts_test.exs
      """)
    end
  end

  # Cap: past a couple of dozen changed lines the diff has stopped being the
  # thing you read and the two files are.
  @max_diff_lines 40

  defp diff(recorded, rendered) do
    recorded
    |> String.split("\n")
    |> List.myers_difference(String.split(rendered, "\n"))
    |> Enum.flat_map(fn
      {:eq, _lines} -> []
      {:del, lines} -> Enum.map(lines, &("  - " <> &1))
      {:ins, lines} -> Enum.map(lines, &("  + " <> &1))
    end)
    |> cap()
    |> Enum.join("\n")
  end

  defp cap(lines) when length(lines) <= @max_diff_lines, do: lines

  defp cap(lines) do
    Enum.take(lines, @max_diff_lines) ++
      ["  … and #{length(lines) - @max_diff_lines} further changed lines"]
  end

  defp update?, do: System.get_env("UPDATE_CONTRACTS") == "1"

  defp canonical(document), do: Jason.encode!(order(document), pretty: true) <> "\n"

  defp order(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), order(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp order(list) when is_list(list), do: Enum.map(list, &order/1)
  defp order(other), do: other
end
