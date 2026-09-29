defmodule Vigil.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        check_auth_password!()
        check_deployment!()

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
           ip: bind_address!(),
           port: Application.fetch_env!(:vigil, :port)}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # config/runtime.exs leaves these nil in :prod when their variable is unset.
  @required [
    vault_path: "VIGIL_VAULT_PATH",
    state_dir: "VIGIL_STATE_DIR",
    issuer: "VIGIL_ISSUER",
    resource: "VIGIL_RESOURCE"
  ]

  defp check_deployment! do
    missing = for {key, var} <- @required, Application.get_env(:vigil, key) in [nil, ""], do: var

    if missing != [] do
      raise "#{Enum.join(missing, ", ")} not set. Check /etc/vigil/env (see deploy/vigil.env.example)."
    end
  end

  defp bind_address! do
    bind = Application.fetch_env!(:vigil, :bind)

    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, ip} -> ip
      {:error, _} -> raise "VIGIL_BIND is not an IP address: #{inspect(bind)}"
    end
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
