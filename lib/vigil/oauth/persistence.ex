defmodule Vigil.OAuth.Persistence do
  @moduledoc """
  What the authorization server remembers, as a value its callers hold rather
  than a module they name (`docs/design.md`, "OAuth persistence is reached
  through a value").

  This is the **contract**: nineteen questions, which is the whole of what the
  OAuth modules ask of storage. A registered client written, read, counted,
  listed and deleted, an authorization code written and taken, a token
  written, read, listed, deleted and revoked by family or all at once, the
  consent password attempts counted per address, the CIMD cache read and
  written — and the janitor's sweep, which is part of this surface rather than
  a concern of its own: it asks persistence to drop what has expired, and
  every expiry it drops belongs to one of the tables above — a registered
  client that never received a code included.

  The listing and deleting questions are the operator's (`Vigil.OAuth.Grants`,
  `scripts/grants.sh`): nothing on a request path asks them.

  The **production adapter** is `Vigil.OAuth.Store.over_tables/0`, a function
  beside the `:dets`/`:ets` implementation it wires, rather than closures
  assembled by a caller — six modules ask these questions, and an adapter
  built at the call site would exist six times. The **second adapter** is
  `Vigil.OAuth.Persistence.Memory`, which the suite runs on;
  `test/vigil/oauth/persistence_test.exs` holds both to every claim below and
  is the only test that opens a `:dets` file.

  No field has a default, and the struct is built by `struct!/2` — the same
  shape and the same rule as `Vigil.Git` and `Vigil.Vault.Facts`: a question
  added here and left unwired fails at construction rather than answering.
  Answering is what it must not do: a `get_token` that answers `:error` turns
  every token into an unknown one, and a `rate_limited?` that answers `false`
  turns the consent lockout off — every plausible answer to a question nobody
  wired sits on the wrong side of a gate.
  """

  @enforce_keys [
    ## Clients
    # Write a registered client's record. :ok, or {:error, reason} as for a
    # code below. Keyed by the client_id itself: it is public, published in
    # every authorization request, and grants nothing on its own.
    :put_client,
    # {:ok, attrs} | :error.
    :get_client,
    # How many client records are stored: a non-negative integer. What the
    # registration cap (`Vigil.OAuth.Client.max_clients/0`) is checked against.
    :count_clients,
    # Every stored client, as [{client_id, attrs}] in no particular order.
    :list_clients,
    # Delete a client's record and every authorization code issued to it, so
    # none is redeemed after the client is gone. Its tokens are not touched
    # here: they are revoked by grant, above the seam. :ok, also for a client
    # that was never stored.
    :delete_client,

    ## Authorization codes
    #
    # A code and a token are asked about by their value and kept under its
    # digest, `Vigil.OAuth.Token.digest/1` — never under the value itself, so
    # a copy of the state holds nothing a caller could present. Hashing is the
    # adapter's, before every write, lookup and delete; no caller ever holds
    # a digest.
    #
    # Write a minted code's record. :ok, or {:error, reason} when the write
    # did not reach the disk — `stored!/1` turns that into a refusal.
    :put_code,
    # Look one up and delete it in the same breath — a code is one-time use.
    # {:ok, attrs} | :error.
    :take_code,

    ## Tokens (access and refresh alike)
    # Write a token record, and rewrite one: rotation marks a refresh token
    # spent by putting it back. :ok, or {:error, reason} as for a code.
    :put_token,
    # {:ok, attrs} | :error.
    :get_token,
    # :ok. Expiry deletes; rotation deliberately does not
    # (Vigil.OAuth.Token.spend_refresh/4).
    :delete_token,
    # Delete every token descended from one authorization grant — the replay
    # defence of RFC 9700 §4.14.2. A nil grant revokes nothing. :ok.
    :revoke_grant,
    # Every stored token record — access, refresh and spent refresh alike — as
    # a list of attrs, in no particular order. The attrs only: a token's value
    # is not stored, and its digest never leaves the adapter.
    :list_tokens,
    # Delete every token and every authorization code: every grant at once,
    # a record from before grants existed included. Clients stay registered.
    # :ok.
    :revoke_all,

    ## Consent password attempts, per address
    # Whether this address is locked out at `now`. boolean.
    :rate_limited?,
    # Count one wrong password against it. :ok.
    :record_failure,
    # Forget an address's attempts — the right password did. :ok.
    :reset_rate_limit,

    ## The CIMD cache
    # {:ok, doc} | :error. Answers :error for an entry whose hour is up.
    :cimd_cache_get,
    # :ok.
    :cimd_cache_put,

    ## The janitor's sweep
    # Drop every record above whose expiry has passed at `now`, and every
    # client `Vigil.OAuth.Client.unused?/2` says was never handed a code in
    # time. :ok.
    :sweep_expired
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  # What the answers above are measured against: two numbers for the consent
  # lockout, one for the cache's hour. They live with the contract rather than
  # with either adapter because both have to agree on them — "the lockout
  # expires with its window" is a claim the suite runs against both, and a
  # window each adapter picked for itself would make that claim mean two
  # different things.
  #
  # The *rules* applied under them are deliberately not shared: each adapter
  # decides for itself what a window is made of and when it rolls over, which
  # is what leaves the contract suite something to catch.
  @rate_limit_window 900
  @rate_limit_max_attempts 5
  @cimd_ttl 3600

  @doc "How long an address's failed-password window lasts, in seconds."
  @spec rate_limit_window() :: pos_integer()
  def rate_limit_window, do: @rate_limit_window

  @doc "How many wrong passwords an address may spend inside one window."
  @spec rate_limit_max_attempts() :: pos_integer()
  def rate_limit_max_attempts, do: @rate_limit_max_attempts

  @doc "How long a cached CIMD document stays good for, in seconds."
  @spec cimd_ttl() :: pos_integer()
  def cimd_ttl, do: @cimd_ttl

  defmodule Unavailable do
    @moduledoc """
    Raised when a client, a code or a token could not be stored — a full
    disk, the `:dets` size limit — and when the client table is at its cap
    (`reason: :client_cap`). The value that was minted is never handed out: a
    credential nobody can look up again is worse than a refusal, because the
    caller believes it holds one. `Vigil.OAuth.Flow` answers it as
    `temporarily_unavailable`; a seeding task dies of it without printing a
    token.
    """
    defexception [:reason]

    @impl true
    def message(%{reason: reason}),
      do: "OAuth state could not be written: #{inspect(reason)}"
  end

  @doc """
  Passes `:ok` through and raises `Unavailable` for the `{:error, reason}` a
  write answers when it did not persist. Every write whose value is handed
  out afterwards goes through here, so no code or token leaves the server
  that was not stored first.
  """
  @spec stored!(:ok | {:error, term()}) :: :ok
  def stored!(:ok), do: :ok
  def stored!({:error, reason}), do: raise(Unavailable, reason: reason)

  @doc """
  Builds a persistence adapter from an answer to every one of the nineteen
  questions.

  Raises `ArgumentError` when a field is missing or unknown, which is the
  point: an unwired question must fail where the adapter is built, not answer
  something plausible at the moment a token is verified against it.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)
end
