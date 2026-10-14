defmodule Accentone.RealSocketTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Accentone.Fixtures
  alias Accentone.Palette
  alias Accentone.Stub
  alias Accentone.TelemetryCapture
  alias Accentone.TestServer

  # `Req.Test` injects a plug and never touches `Finch`, so exactly two
  # claims need a real socket. Both live here, and the module is `async: false`
  # because `TestServer.start/1` binds a real port.
  #
  #   1. **A retry re-uploads through `Finch`.** The attempts are counted on the
  #      wire, so this proves the approved attempt is handed back to the transport
  #      rather than short-circuited. The stub-driven counting tests in
  #      `client_test.exs` prove the retry happens at all; only a real socket
  #      proves the body goes out again.
  #   2. **The library never logs or telemetries the request body.** A
  #      `[:finch, :send, :start]` handler is attached because that is the one
  #      path the body can take into a telemetry payload; the assertion is made
  #      the right way round — only the *library's own* telemetry and logs are
  #      checked — so a future Finch that stops emitting the body leaves this
  #      test passing.

  @png Fixtures.png()
  @needle Base.encode64(Fixtures.png())

  # A chat-surface provider pointing at the test server, which serves
  # `/v1/chat/completions` (`ReqLLM` appends the path to the base).
  defp model(port),
    do: %{provider: :lmstudio, id: "real-socket", base_url: "http://127.0.0.1:#{port}/v1"}

  defp image_uri(body) do
    [%{"content" => [_text, image]}] = body["messages"]
    image["image_url"]["url"]
  end

  defp drain(ref, acc \\ []) do
    receive do
      {^ref, event, measurements, metadata} ->
        drain(ref, [inspect({event, measurements, metadata}) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a retry re-uploads the body through Finch" do
    test_pid = self()
    attempts = :counters.new(1, [])

    port =
      TestServer.start(fn conn, body ->
        :counters.add(attempts, 1, 1)
        attempt = :counters.get(attempts, 1)
        send(test_pid, {:upload, attempt, body})

        if attempt == 1 do
          # `retry-after: 0` keeps the approved retry immediate: `ReqLLM` honours
          # the header and would otherwise wait its 1000 ms fallback.
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, ~s({"error":"slow down"}))
        else
          Req.Test.json(conn, Stub.success_body(key: "#A1B2C3"))
        end
      end)

    opts = [model: model(port), max_retries: 1, receive_timeout: 2_000]

    assert {:ok, %Palette{}} = Accentone.analyze({:bytes, @png}, opts)

    # Two requests really crossed the socket: the predicate approved the second
    # attempt and handed it back to Finch. Declining would have left one request
    # and an `{:http, 429, _}`.
    assert :counters.get(attempts, 1) == 2

    assert_receive {:upload, 1, first}
    assert_receive {:upload, 2, second}

    # Every attempt is a full re-upload — the same prompt and the same base64
    # image go out again — which is why `:max_retries` is a cost decision.
    assert first["model"] == second["model"]
    assert first["messages"] == second["messages"]
    assert image_uri(first) == "data:image/png;base64," <> @needle
    assert image_uri(second) == image_uri(first)
  end

  test "the library's own telemetry and logs never carry the request body" do
    port =
      TestServer.start(fn conn, _body ->
        Req.Test.json(conn, Stub.success_body(key: "#A1B2C3"))
      end)

    finch = TelemetryCapture.attach([[:finch, :send, :start]])

    accentone =
      TelemetryCapture.attach([
        [:accentone, :analyze, :start],
        [:accentone, :analyze, :stop]
      ])

    on_exit(fn ->
      TelemetryCapture.detach(finch)
      TelemetryCapture.detach(accentone)
    end)

    {result, log} =
      with_log(fn ->
        Accentone.analyze({:bytes, @png}, model: model(port), receive_timeout: 2_000)
      end)

    assert {:ok, %Palette{}} = result

    # The real Finch step fired underneath, so the negative result below is not
    # vacuous: the body did traverse the transport's telemetry.
    assert_receive {^finch, [:finch, :send, :start], _measurements, finch_metadata}

    payloads = drain(accentone)
    assert length(payloads) == 2

    # Informational only, and only for the failure message — see the note above.
    finch_saw_body? = inspect(finch_metadata) =~ @needle

    refute Enum.any?(payloads, &(&1 =~ @needle)),
           "accentone telemetry leaked the request body (Finch emitted it: #{finch_saw_body?})"

    refute log =~ @needle, "a log line carried the request body"
  end
end
