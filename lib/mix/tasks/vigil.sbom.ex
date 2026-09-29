defmodule Mix.Tasks.Vigil.Sbom do
  @shortdoc "Writes a CycloneDX SBOM of the release built in this environment"
  @moduledoc """
  Writes a CycloneDX 1.6 software bill of materials (JSON) for the release
  `mix release` builds in the current environment.

      MIX_ENV=prod mix vigil.sbom --output dist/vigil.cdx.json

  The inventory is what goes into the tarball, not everything `mix.lock`
  lists: the Hex packages of the current environment (so `MIX_ENV=prod`
  leaves out credo, dialyxir and the rest of the quality gate), each with the
  version and the package checksum `mix.lock` pins and the licenses its Hex
  metadata declares. A release also bundles the Erlang runtime system (ERTS)
  and the Elixir standard library of the machine that built it, and a
  vulnerability in those is one in vigil, so both are listed too, with the
  versions of the VM running this task — the one `mix release` copies them
  from.

  The output is deterministic: the same lock, dependencies and toolchain give
  the same bytes. The only time in it is `SOURCE_DATE_EPOCH`, when that is set
  (the release workflow sets it to the commit time); without it there is none.

  There is no SBOM generator from Hex behind this on purpose: it would be one
  more third-party package running in the release job, and all it would read
  is `mix.lock` and each dependency's `hex_metadata.config`.
  """
  use Mix.Task

  @spec_version "1.6"

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [output: :string])
    output = opts[:output] || Mix.raise("Usage: mix vigil.sbom --output <path>")

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(bom(), pretty: true) <> "\n")
    Mix.shell().info("Wrote #{output}")
  end

  defp bom do
    config = Mix.Project.config()
    lock = read_lock(Path.join(File.cwd!(), "mix.lock"))

    packages =
      Mix.Project.deps_paths()
      |> Enum.flat_map(fn {app, path} -> package(lock[app], path) end)
      |> Enum.sort_by(& &1.name)

    app = Atom.to_string(config[:app])
    root = purl(app, config[:version])
    direct = Enum.map(config[:deps], &Atom.to_string(elem(&1, 0)))

    %{
      "bomFormat" => "CycloneDX",
      "specVersion" => @spec_version,
      "version" => 1,
      "metadata" => metadata(app, config[:version], root),
      "components" => Enum.map(packages, &component/1) ++ runtime_components(),
      "dependencies" => [
        dependency(root, direct, packages)
        | Enum.map(packages, &dependency(&1.purl, &1.requires, packages))
      ]
    }
  end

  defp metadata(app, version, root) do
    base = %{
      "component" => %{
        "type" => "application",
        "bom-ref" => root,
        "name" => app,
        "version" => version,
        "purl" => root,
        "licenses" => [%{"license" => %{"id" => "MIT"}}]
      }
    }

    case System.get_env("SOURCE_DATE_EPOCH") do
      nil ->
        base

      epoch ->
        at = epoch |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_iso8601()
        Map.put(base, "timestamp", at)
    end
  end

  # Only a Hex package has a version and a checksum to pin; a path or git
  # dependency would need another kind of identifier, and vigil has none.
  defp package({:hex, name, version, _inner, _managers, requires, _repo, checksum}, path) do
    name = Atom.to_string(name)

    [
      %{
        name: name,
        version: version,
        purl: purl(name, version),
        checksum: checksum,
        licenses: licenses(path),
        requires: Enum.map(requires, fn {dep, _req, _opts} -> Atom.to_string(dep) end)
      }
    ]
  end

  defp package(_other, _path), do: []

  defp licenses(path) do
    case :file.consult(String.to_charlist(Path.join(path, "hex_metadata.config"))) do
      {:ok, terms} ->
        terms |> Map.new() |> Map.get("licenses", []) |> Enum.sort()

      {:error, reason} ->
        Mix.raise(
          "Cannot read the Hex metadata in #{path} (#{inspect(reason)}); run mix deps.get"
        )
    end
  end

  defp component(package) do
    %{
      "type" => "library",
      "bom-ref" => package.purl,
      "name" => package.name,
      "version" => package.version,
      "purl" => package.purl,
      "hashes" => [%{"alg" => "SHA-256", "content" => package.checksum}],
      "licenses" => Enum.map(package.licenses, &license/1)
    }
  end

  # An SPDX identifier where Hex declares one, and the declared text where it
  # does not (yamerl declares "BSD 2-Clause"): a name is what CycloneDX has for
  # that, and translating it here would be a claim about the package nobody
  # checked at build time.
  defp license(declared) do
    if declared =~ ~r/^[A-Za-z0-9.+-]+$/ do
      %{"license" => %{"id" => declared}}
    else
      %{"license" => %{"name" => declared}}
    end
  end

  # What `mix release` copies from the VM that built it (`include_erts` is on
  # by default): the runtime system with Erlang/OTP's applications, and
  # Elixir's standard library.
  defp runtime_components do
    otp = otp_version()
    erts = List.to_string(:erlang.system_info(:version))
    elixir = System.version()

    [
      %{
        "type" => "platform",
        "bom-ref" => "pkg:github/erlang/otp@OTP-#{otp}",
        "name" => "erlang-otp",
        "version" => otp,
        "description" =>
          "Erlang/OTP #{otp} with the Erlang runtime system (ERTS #{erts}), bundled in the release",
        "purl" => "pkg:github/erlang/otp@OTP-#{otp}",
        "licenses" => [%{"license" => %{"id" => "Apache-2.0"}}],
        "properties" => [%{"name" => "vigil:erts-version", "value" => erts}]
      },
      %{
        "type" => "framework",
        "bom-ref" => "pkg:github/elixir-lang/elixir@v#{elixir}",
        "name" => "elixir",
        "version" => elixir,
        "description" => "Elixir #{elixir} standard library, bundled in the release",
        "purl" => "pkg:github/elixir-lang/elixir@v#{elixir}",
        "licenses" => [%{"license" => %{"id" => "Apache-2.0"}}]
      }
    ]
  end

  # The full version (27.3.4) is a file of the installation; the VM itself
  # only reports the major release (27).
  defp otp_version do
    release = List.to_string(:erlang.system_info(:otp_release))
    file = Path.join([List.to_string(:code.root_dir()), "releases", release, "OTP_VERSION"])

    case File.read(file) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> release
    end
  end

  # Edges only to packages in the inventory: an optional dependency this
  # environment does not build is not part of the release.
  defp dependency(ref, requires, packages) do
    depends_on =
      for name <- Enum.sort(requires),
          package = Enum.find(packages, &(&1.name == name)),
          do: package.purl

    %{"ref" => ref, "dependsOn" => depends_on}
  end

  defp purl(name, version), do: "pkg:hex/#{name}@#{version}"

  # mix.lock is an Elixir term made only of literals. It is read as data,
  # parsed and its literals converted, rather than evaluated as code. Mix
  # writes its keys quoted ("bandit":), which the parser would warn about.
  defp read_lock(path) do
    path |> File.read!() |> Code.string_to_quoted!(emit_warnings: false) |> literal()
  end

  defp literal({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal(k), literal(v)} end)
  defp literal({:{}, _, elements}), do: elements |> Enum.map(&literal/1) |> List.to_tuple()
  defp literal({left, right}), do: {literal(left), literal(right)}
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp literal(other), do: Mix.raise("mix.lock holds a non-literal: #{Macro.to_string(other)}")
end
