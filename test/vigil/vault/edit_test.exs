defmodule Vigil.Vault.EditTest do
  use ExUnit.Case, async: true

  alias Vigil.Index
  alias Vigil.Vault.Edit

  # A chunk as Edit needs it: heading, heading_line, body_end_line. Every
  # other field on Index.Chunk is irrelevant to the splice.
  defp chunk(heading, heading_line, body_end_line) do
    %Index.Chunk{heading: heading, heading_line: heading_line, body_end_line: body_end_line}
  end

  # Three ## sections, no nesting. "Second" is mid-file (a heading follows
  # it); "Third" is last (EOF follows it).
  @three_sections """
  # Notes

  ## First
  First body.

  ## Second
  Second body.

  ## Third
  Third body.
  """

  defp second, do: chunk("Second", 6, 8)
  defp third, do: chunk("Third", 9, 10)

  # ## First is followed directly by ### Nested — a deeper heading, but the
  # flat chunk model (docs/design.md, "Chunking") makes it a sibling chunk,
  # not part of First's body.
  @nested_heading """
  # Notes

  ## First
  First body.

  ### Nested
  Nested body.

  ## Second
  Second body.
  """

  defp first_with_nested_sibling, do: chunk("First", 3, 5)

  describe "replace_body/3" do
    test "replaces a mid-file section's body, heading and rest of file untouched" do
      assert {:ok, result} = Edit.replace_body(@three_sections, second(), "New second body.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             New second body.
             ## Third
             Third body.
             """
    end

    test "replaces the last section's body, running to EOF" do
      assert {:ok, result} = Edit.replace_body(@three_sections, third(), "New third body.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             ## Third
             New third body.
             """
    end

    test "refuses a nil chunk" do
      assert {:error, _} = Edit.replace_body(@three_sections, nil, "text")
    end

    test "refuses a chunk without a heading" do
      pre_chunk = chunk(nil, nil, 4)
      assert {:error, _} = Edit.replace_body(@three_sections, pre_chunk, "text")
    end
  end

  describe "delete_section/2" do
    test "deletes a section that has a deeper heading under it, leaving that heading in place" do
      assert {:ok, result} = Edit.delete_section(@nested_heading, first_with_nested_sibling())

      assert result == """
             # Notes

             ### Nested
             Nested body.

             ## Second
             Second body.
             """
    end

    test "deletes the last section, running to EOF" do
      assert {:ok, result} = Edit.delete_section(@three_sections, third())

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             """
    end

    test "refuses a nil chunk" do
      assert {:error, _} = Edit.delete_section(@three_sections, nil)
    end

    test "refuses a chunk without a heading" do
      pre_chunk = chunk(nil, nil, 4)
      assert {:error, _} = Edit.delete_section(@three_sections, pre_chunk)
    end
  end

  describe "append/3" do
    test "{:section, chunk} appends at the end of a mid-file section's body" do
      assert {:ok, result} =
               Edit.append(@three_sections, {:section, second()}, "New line under second.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             New line under second.
             ## Third
             Third body.
             """
    end

    test "{:section, chunk} appends at the end of the last heading's body, running to EOF" do
      assert {:ok, result} =
               Edit.append(@three_sections, {:section, third()}, "New content here.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             ## Third
             Third body.
             New content here.
             """
    end

    test "{:new_section, heading} opens a fresh section at the end of the file" do
      assert {:ok, result} =
               Edit.append(@three_sections, {:new_section, "Fourth"}, "Fourth body.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             ## Third
             Third body.

             ## Fourth
             Fourth body.
             """
    end

    test ":end appends at EOF with no heading" do
      assert {:ok, result} = Edit.append(@three_sections, :end, "Trailing note.")

      assert result == """
             # Notes

             ## First
             First body.

             ## Second
             Second body.

             ## Third
             Third body.

             Trailing note.
             """
    end

    test "{:section, chunk} refuses a nil chunk" do
      assert {:error, _} = Edit.append(@three_sections, {:section, nil}, "text")
    end
  end
end
