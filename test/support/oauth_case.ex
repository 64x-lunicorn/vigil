defmodule Vigil.OAuthCase do
  @moduledoc """
  Shared setup helper for OAuth-protected MCP tests: configures issuer/resource/
  password application env and starts a fresh `Vigil.OAuth.Store` against a
  throwaway state dir. Call `setup!/0` from the test module's own `setup do ... end`.
  """

  @doc """
  Returns `%{state_dir:, issuer:, resource:, auth_password:, persistence:}`.
  Registers `on_exit` cleanup.

  `persistence` is the `:dets`/`:ets` adapter over the store it just started —
  the value every OAuth module now asks its questions through, and the one
  production runs on. A test that wants a different one builds it itself.
  """
  def setup! do
    state_dir =
      Path.join(System.tmp_dir!(), "vigil_oauth_test_#{System.unique_integer([:positive])}")

    env = [
      issuer: "https://vault.factory-lab.org",
      resource: "https://vault.factory-lab.org/mcp",
      auth_password: "correct-horse-battery-staple"
    ]

    previous = for {k, _} <- env, do: {k, Application.get_env(:vigil, k)}
    for {k, v} <- env, do: Application.put_env(:vigil, k, v)

    ExUnit.Callbacks.on_exit(fn ->
      for {k, v} <- previous, do: Application.put_env(:vigil, k, v)
      File.rm_rf(state_dir)
    end)

    ExUnit.Callbacks.start_supervised!({Vigil.OAuth.Store, state_dir: state_dir})

    Map.new(env)
    |> Map.put(:state_dir, state_dir)
    |> Map.put(:persistence, Vigil.OAuth.Store.over_tables())
  end
end
