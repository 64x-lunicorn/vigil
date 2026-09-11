defmodule Vigil.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        check_auth_password!()

        # What the deployment says about itself, read once here and handed to
        # the two children that need it. Everything below takes it as an
        # option, so this is the only place it is resolved and the only place
        # an environment read for one of those settings belongs.
        settings = Vigil.Settings.from_env()

        [
          {Vigil.Store,
           vault_path: Application.fetch_env!(:vigil, :vault_path),
           exclude: Application.fetch_env!(:vigil, :exclude),
           git_remote: Application.fetch_env!(:vigil, :git_remote),
           settings: settings},
          Vigil.MCP.Envelope,
          Vigil.RateLimit,
          {Vigil.OAuth.Store, state_dir: Application.fetch_env!(:vigil, :state_dir)},
          Vigil.OAuth.Janitor,
          {Bandit,
           plug: {Vigil.MCP.Server, settings: settings},
           port: Application.fetch_env!(:vigil, :port)}
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
        VIGIL_AUTH_PASSWORD is missing or shorter than 12 characters.
        A publicly reachable authorization server without a strong password is an open door to the vault.
        """
    end
  end
end
