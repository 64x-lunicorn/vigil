defmodule Vigil.Vault.DecisionTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.Decision

  # Every write shape, with one complete answer for it. A decision is what the
  # write gate hands the writer: a field its operation needs and cannot answer
  # has to stop the write here, at construction, and not as a KeyError inside
  # Vigil.Store's write sequence.
  @shapes [
    {Decision.Create,
     [
       path: "bike/x.md",
       normalized_from: nil,
       create_project_dir: nil,
       type: :reference,
       starts: nil,
       ends: nil
     ]},
    {Decision.Append, [path: "bike/x.md", target: :end]},
    {Decision.Section, [path: "bike/x.md", chunk: %{id: "bike/x.md#fueling"}]},
    {Decision.RewriteNote, [path: "bike/x.md"]},
    {Decision.UpdateFrontmatter, [path: "bike/x.md", type: :reference, starts: nil, ends: nil]},
    {Decision.DeleteNote, [path: "bike/x.md", backlinks: []]},
    {Decision.MoveNote, [from: "bike/a.md", to: "bike/b.md"]}
  ]

  test "every shape builds from a complete answer" do
    for {shape, fields} <- @shapes do
      assert struct!(shape, fields).__struct__ == shape
    end
  end

  test "a field the operation needs cannot be left unstated" do
    for {shape, fields} <- @shapes, {field, _answer} <- fields do
      assert_raise ArgumentError, ~r/#{field}/, fn ->
        struct!(shape, Keyword.delete(fields, field))
      end
    end
  end

  test "a field the shape does not have raises" do
    assert_raise KeyError, fn ->
      struct!(Decision.MoveNote, from: "bike/a.md", to: "bike/b.md", domain: "bike")
    end
  end
end
