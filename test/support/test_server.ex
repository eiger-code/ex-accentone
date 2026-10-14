defmodule Accentone.TestServer do
  @moduledoc false

  # The real-socket server: a minimal `Plug` started under `Bandit` on an
  # ephemeral port, for the two claims `Req.Test` cannot reach because it
  # injects a plug and never touches `Finch`.
  #
  # This is where `Bypass` used to be. Bypass hard-depends on `plug_cowboy`, so
  # two tests dragged `cowboy`, `cowlib`, and `ranch` into `mix.lock` — and
  # `cowlib` is where the one advisory in the tree lives. Bandit's closure is
  # pure Elixir (`thousand_island`, `websock`, `plug`), so the test toolchain no
  # longer carries an Erlang HTTP server at all, and `mix hex.audit` is clean
  # without an allowlist.
  #
  # The responder is a `(Plug.Conn.t(), decoded_body -> Plug.Conn.t())` supplied
  # by the test, which keeps the per-test behaviour — counting attempts, picking
  # a status — in the test rather than behind a routing DSL here.

  import Plug.Conn

  @doc """
  Start a listener on an ephemeral loopback port and return the port it bound.

  The listener is started under ExUnit's per-test supervisor, so it is stopped
  when the test finishes and no port outlives the test that opened it. `port: 0`
  is what makes the port ephemeral: nothing has to reserve one in advance, so two
  runs cannot collide. `startup_log: false` keeps Bandit's one-line banner out of
  the suite's output, and the loopback `ip` keeps a test listener off every other
  interface — which also makes `localhost`'s IPv4/IPv6 ambiguity impossible, so
  the caller can dial `127.0.0.1` outright.
  """
  @spec start((Plug.Conn.t(), term() -> Plug.Conn.t())) :: integer()
  def start(responder) when is_function(responder, 2) do
    pid =
      ExUnit.Callbacks.start_supervised!({
        Bandit,
        plug: {__MODULE__, responder: responder}, ip: {127, 0, 0, 1}, port: 0, startup_log: false
      })

    # `Bandit` returns a bare pid even for `port: 0`; the bound port is only
    # readable back off the listener, which is where `ThousandIsland` keeps it.
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    port
  end

  @doc false
  def init(opts), do: Keyword.fetch!(opts, :responder)

  @doc false
  def call(conn, responder) do
    {:ok, body, conn} = read_body(conn)
    responder.(conn, Jason.decode!(body))
  end
end
