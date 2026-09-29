defmodule Vigil.ConventionsTemplateTest do
  @moduledoc """
  The conventions skill names itself the way `init.sh` installs it.

  An assistant told to `skill_read` a name the vault does not hold gets the
  not-found response, which hands out a key only so a fresh vault can be
  bootstrapped. So the name the template gives itself, and every name it tells
  the assistant to read, is held to the one `init.sh` installs it under — the
  template's file name (`install_conventions_skill` in `scripts/lib.sh`), read
  out of the script rather than stated a second time here.
  """
  use ExUnit.Case, async: true

  alias Vigil.Git.CommitLog
  alias Vigil.{Markdown, Skills}

  @init Path.expand("../../scripts/init.sh", __DIR__)

  # The template init.sh installs, and the name it lands under.
  defp installed do
    script = File.read!(@init)

    [_, template] =
      Regex.run(
        ~r/install_conventions_skill "\$VAULT" "\$\{SCRIPT_DIR\}\/(templates\/[^"]+\.md)"/,
        script
      )

    {Path.basename(template, ".md"), Path.join(Path.dirname(@init), template)}
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

  # init.sh commits the skill itself because the server will not: the name it
  # installs is one skill_write refuses, however it is asked.
  test "the installed skill is one MCP cannot write" do
    {name, template} = installed()

    vault =
      Path.join(System.tmp_dir!(), "vigil_conventions_#{System.unique_integer([:positive])}")

    File.mkdir_p!(vault)
    on_exit(fn -> File.rm_rf(vault) end)

    target = %{
      vault_path: vault,
      git_remote: "origin",
      git_branch: "main",
      git: CommitLog.new(vault)
    }

    assert {:error, msg} = Skills.write(name, File.read!(template), target, confirm: true)
    assert msg =~ "is protected"
  end
end
