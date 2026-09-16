defmodule Vigil.ConventionsTemplateTest do
  @moduledoc """
  The conventions skill names itself the way `init.sh` installs it.

  An assistant told to `skill_read` a name the vault does not hold gets the
  not-found response, which hands out a key only so a fresh vault can be
  bootstrapped. So the name the template gives itself, and every name it tells
  the assistant to read, is held to the one `init.sh` sends to `skill_write` —
  read out of the script rather than stated a second time here.
  """
  use ExUnit.Case, async: true

  alias Vigil.Markdown

  @init Path.expand("../../scripts/init.sh", __DIR__)

  # The skill_write call that installs the template, and the template file the
  # content it sends is read from.
  defp installed do
    script = File.read!(@init)

    [_, template] = Regex.run(~r/cat "\$\{SCRIPT_DIR\}\/(templates\/[^"]+\.md)"/, script)

    [_, name] =
      Regex.run(~r/"skill_write" \\\n\s*"\{\\"name\\":\\"([a-z0-9_-]+)\\"/, script)

    {name, Path.join(Path.dirname(@init), template)}
  end

  test "the template's frontmatter name is the name init.sh installs it under" do
    {name, template} = installed()

    {:ok, yaml, _body, _offset} = template |> File.read!() |> Markdown.frontmatter()
    assert {:ok, %{"name" => ^name}} = YamlElixir.read_from_string(yaml)
  end

  test "every skill the template tells the assistant to read is the installed name" do
    {name, template} = installed()

    reads =
      Regex.scan(~r/`skill_read` on `([^`]+)`/, File.read!(template), capture: :all_but_first)

    assert reads != []
    assert Enum.uniq(List.flatten(reads)) == [name]
  end
end
