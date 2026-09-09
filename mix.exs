defmodule Vigil.MixProject do
  use Mix.Project

  def project do
    [
      app: :vigil,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :eex, :inets, :ssl],
      mod: {Vigil.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:tz, "~> 0.28"},
      {:plug, "~> 1.16"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The exact gate CI enforces, runnable in one command before pushing.
  # Keep this list and .github/workflows/ci.yml in step: a check that only
  # exists in CI is a check contributors discover too late.
  #
  # `hex.audit` runs through `cmd mix` on purpose. It is provided by the Hex
  # *archive*, and `mix compile --force` earlier in the same VM purges the
  # archive from the code path — the task then fails with "could not be
  # found", which reads like a broken installation rather than an ordering
  # artefact. A separate OS process makes the alias order-independent. In CI
  # every step is its own process anyway, so the two stay equivalent.
  defp aliases do
    [
      ci: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "cmd mix hex.audit",
        "deps.audit",
        "test",
        "dialyzer"
      ]
    ]
  end

  # The PLT lives outside _build so CI can cache it on its own key: it depends
  # on the Erlang/Elixir pair and the dependency set, not on our source.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit, :eex, :inets, :ssl, :public_key],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unknown]
    ]
  end

  defp releases do
    [
      vigil: [
        include_executables_for: [:unix]
      ]
    ]
  end
end
