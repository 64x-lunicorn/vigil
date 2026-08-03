defmodule Vigil.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        check_auth_password!()

        [
          {Vigil.Store,
           vault_path: Application.fetch_env!(:vigil, :vault_path),
           exclude: Application.fetch_env!(:vigil, :exclude),
           git_remote: Application.fetch_env!(:vigil, :git_remote)},
          Vigil.MCP.Envelope,
          Vigil.MCP.RateLimit,
          {Vigil.OAuth.Store, state_dir: Application.fetch_env!(:vigil, :state_dir)},
          Vigil.OAuth.Janitor,
          {Bandit, plug: Vigil.MCP.Server, port: Application.fetch_env!(:vigil, :port)}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp check_auth_password! do
    case Application.fetch_env(:vigil, :auth_password) do
      {:ok, password} when is_binary(password) and byte_size(password) >= 12 ->
        :ok

      _ ->
        raise """
        VIGIL_AUTH_PASSWORD fehlt oder ist kürzer als 12 Zeichen.
        Ein öffentlich erreichbarer Autorisierungsserver ohne starkes Passwort ist ein offenes Tor zum Vault.
        """
    end
  end
end
