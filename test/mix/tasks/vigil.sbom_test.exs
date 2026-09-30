defmodule Mix.Tasks.Vigil.SbomTest do
  @moduledoc """
  The SBOM a release carries: CycloneDX, one component per Hex package the
  environment builds with the version and checksum mix.lock pins, and the
  Erlang runtime and Elixir the release bundles. The release workflow runs it
  under `MIX_ENV=prod`; here it runs under `test`, whose package set is a
  superset, so the assertions name packages both environments share.
  """
  # Reads and sets SOURCE_DATE_EPOCH, which is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Vigil.Sbom

  setup do
    dir = Path.join(System.tmp_dir!(), "vigil_sbom_#{System.unique_integer([:positive])}")
    previous = System.get_env("SOURCE_DATE_EPOCH")
    System.delete_env("SOURCE_DATE_EPOCH")
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      if previous, do: System.put_env("SOURCE_DATE_EPOCH", previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp generate(dir, name \\ "bom.cdx.json") do
    path = Path.join(dir, name)
    Sbom.run(["--output", path])
    {File.read!(path), path |> File.read!() |> Jason.decode!()}
  end

  defp component(bom, name), do: Enum.find(bom["components"], &(&1["name"] == name))

  test "it is a CycloneDX document about vigil at the project's version", %{dir: dir} do
    {_raw, bom} = generate(dir)

    assert bom["bomFormat"] == "CycloneDX"
    assert bom["specVersion"] == "1.6"
    assert bom["metadata"]["component"]["name"] == "vigil"
    assert bom["metadata"]["component"]["version"] == Mix.Project.config()[:version]
    assert bom["metadata"]["component"]["licenses"] == [%{"license" => %{"id" => "MIT"}}]
  end

  test "a Hex package carries the locked version, its checksum and its license", %{dir: dir} do
    {_raw, bom} = generate(dir)
    {:hex, :bandit, version, _, _, _, _, checksum} = Mix.Dep.Lock.read()[:bandit]

    assert component(bom, "bandit") == %{
             "type" => "library",
             "bom-ref" => "pkg:hex/bandit@#{version}",
             "name" => "bandit",
             "version" => version,
             "purl" => "pkg:hex/bandit@#{version}",
             "hashes" => [%{"alg" => "SHA-256", "content" => checksum}],
             "licenses" => [%{"license" => %{"id" => "MIT"}}]
           }
  end

  test "a license Hex declares by a name that is not an SPDX id stays a name", %{dir: dir} do
    {_raw, bom} = generate(dir)

    assert component(bom, "yamerl")["licenses"] == [%{"license" => %{"name" => "BSD 2-Clause"}}]
  end

  test "the bundled Erlang runtime and Elixir are listed with the building VM's versions",
       %{dir: dir} do
    {_raw, bom} = generate(dir)
    otp = component(bom, "erlang-otp")
    erts = List.to_string(:erlang.system_info(:version))

    assert String.starts_with?(otp["version"], List.to_string(:erlang.system_info(:otp_release)))
    assert otp["properties"] == [%{"name" => "vigil:erts-version", "value" => erts}]
    assert otp["description"] =~ "ERTS #{erts}"
    assert component(bom, "elixir")["version"] == System.version()
  end

  test "vigil depends on its direct dependencies, and they on theirs", %{dir: dir} do
    {_raw, bom} = generate(dir)
    graph = Map.new(bom["dependencies"], &{&1["ref"], &1["dependsOn"]})
    ref = fn name -> component(bom, name)["bom-ref"] end

    vigil = graph[bom["metadata"]["component"]["bom-ref"]]
    assert ref.("bandit") in vigil
    assert ref.("plug") in vigil
    refute ref.("thousand_island") in vigil
    assert ref.("thousand_island") in graph[ref.("bandit")]
  end

  test "the same inputs give the same bytes, with no time unless SOURCE_DATE_EPOCH names one",
       %{dir: dir} do
    {first, bom} = generate(dir, "a.json")
    {second, _} = generate(dir, "b.json")

    assert first == second
    refute Map.has_key?(bom["metadata"], "timestamp")

    System.put_env("SOURCE_DATE_EPOCH", "1767225600")
    {_raw, bom} = generate(dir, "c.json")
    assert bom["metadata"]["timestamp"] == "2026-01-01T00:00:00Z"
  end

  test "it needs to be told where to write" do
    assert_raise Mix.Error, ~r/--output/, fn -> Sbom.run([]) end
  end
end
