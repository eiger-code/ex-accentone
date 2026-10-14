defmodule Accentone.ClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Accentone.Client
  alias Accentone.Config
  alias Accentone.Fixtures
  alias Accentone.Stub
  alias Accentone.TelemetryCapture

  # What `Accentone.Client` is responsible for, one row per claim: the parts of
  # the request accentone contributes, the deadline, and the error mapping into
  # `t:Accentone.error_reason/0`.
  #
  # The wire format is deliberately *not* pinned here any more. `ReqLLM` owns the
  # body, the cap-key spelling, the surface, and the retry predicate, so a test
  # that read them off the stub would be asserting a dependency's behaviour and
  # would fail on its next release for no reason. What is asserted about the
  # request is the part accentone chooses: the schema it declares, the data URI
  # it builds from sniffed bytes, the credential it does or does not send, and
  # the fact that `:reqllm_options` reaches the wire.
  #
  # Two harness decisions are load-bearing:
  #
  #   * the config's model is an inline `:lmstudio` spec, because that is a
  #     **chat-surface** provider. The default `"openai:gpt-4o"` routes to
  #     `/v1/responses`, where the stub's chat-shaped body decodes to an empty
  #     message. Its id doubles as this file's telemetry marker.
  #   * the caller's `req_http_options` are merged *into* the stub's, not added
  #     beside them: `Keyword.get/3` returns the first hit, so a second
  #     `:req_http_options` entry would silently drop the stub.

  @png Fixtures.png()

  # A **loopback** endpoint on purpose: `Config.warn_plaintext/1` warns for a
  # non-loopback `http://` host, credential or not, so a LAN name would make the
  # whole file log warnings.
  @model %{provider: :lmstudio, id: "client-probe", base_url: "http://127.0.0.1:1234/v1"}
  @probe "lmstudio:client-probe"

  # `ReqLLM` normalizes the provider's `usage` into atom keys, and a reply that
  # carries no `usage` normalizes to zeros with `usage_reported` false rather
  # than to `nil` — so the assertions below are about the normalized shape.
  @usage %{input_tokens: 380, output_tokens: 130, total_tokens: 510}

  defp config(opts \\ []) do
    reqllm_options = Keyword.get(opts, :reqllm_options, [])

    # The caller's Req options are merged *into* the stub's rather than put
    # beside them: `Keyword.get/3` returns the first hit, so a second
    # `:req_http_options` entry would silently drop the stub.
    req_http_options =
      Keyword.merge([plug: Stub.plug()], Keyword.get(reqllm_options, :req_http_options, []))

    opts =
      opts
      |> Keyword.put_new(:model, @model)
      |> Keyword.put(
        :reqllm_options,
        Keyword.put(reqllm_options, :req_http_options, req_http_options)
      )

    case Config.resolve(opts) do
      {:ok, config} -> config
      {:error, reason} -> flunk("expected a resolved config, got #{inspect(reason)}")
    end
  end

  defp call(config, prompt \\ "PROMPT") do
    Client.call(config, prompt, @png, "image/png")
  end

  defp ok_body(opts \\ []) do
    Stub.success_body([key: "#A1B2C3", accent: "#D4E5F6"], opts)
  end

  defp authorization(conn) do
    for {"authorization", value} <- conn.req_headers, do: value
  end

  # The captured connection is sent to the **test** process, not to `self()`
  # inside this closure: a finite `:total_timeout` makes `ReqLLM` run the request
  # in its own task, so `self()` in the plug handler is the task's pid and a
  # `send/2` from there never reaches the assertions. Capturing the pid at
  # install time is what makes the payload rows observable at all.
  defp answering(body \\ nil) do
    test = self()

    Stub.install(fn conn ->
      send(test, {:conn, conn})
      Req.Test.json(conn, body || ok_body())
    end)
  end

  defp always_status(status, headers \\ []) do
    Stub.install_attempts(fn conn, _attempt ->
      conn
      |> Plug.Conn.merge_resp_headers(headers)
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => "nope"})
    end)
  end

  # Attaches to the start/stop events, emits the span, and merges the stop
  # measurements into the stop metadata so one map carries everything the
  # assertions need. Returns `{ref, start_meta, stop_merged}`.
  defp emit_span(config, overrides \\ %{}) do
    ref =
      TelemetryCapture.attach(
        [[:accentone, :analyze, :start], [:accentone, :analyze, :stop]],
        filter: &(&1.model == @probe)
      )

    on_exit(fn -> TelemetryCapture.detach(ref) end)

    start = Client.emit_start(config)
    assert_receive {^ref, [:accentone, :analyze, :start], start_measurements, start_meta}

    info =
      Map.merge(
        %{
          start_monotonic: start.monotonic_time,
          usage: @usage,
          dropped: 1,
          dropped_by_field: %{key_colors: 1},
          outcome: :error
        },
        overrides
      )

    assert :ok = Client.emit_stop(config, info)
    assert_receive {^ref, [:accentone, :analyze, :stop], stop_measurements, stop_meta}

    {ref, Map.merge(start_measurements, start_meta), Map.merge(stop_measurements, stop_meta)}
  end

  describe "the request" do
    test "sends the schema, the sniffed data URI, and the credential" do
      answering()

      config = config(api_key: "sk-test", temperature: 0.0, detail: "low", max_tokens: 512)

      assert {:ok, _result} = call(config)
      assert_receive {:conn, conn}
      body = conn.body_params

      assert body["model"] == "client-probe"
      assert body["stream"] == false
      assert body["temperature"] == 0.0
      assert body["max_tokens"] == 512
      # `:top_p` is not an option and never appears.
      refute Map.has_key?(body, "top_p")

      # The schema accentone declares, in the slot the provider expects it.
      assert %{"type" => "json_schema", "json_schema" => %{"schema" => schema}} =
               body["response_format"]

      assert schema["properties"]["key_colors"]["maxItems"] == 3

      assert schema["properties"]["key_colors"]["items"]["properties"]["hex"]["pattern"] ==
               "^#[0-9A-Fa-f]{6}$"

      # The image is a data URI built from the *sniffed* bytes, at the requested
      # detail.
      assert [%{"role" => "user", "content" => [text, image]}] = body["messages"]
      assert text == %{"type" => "text", "text" => "PROMPT"}

      assert image == %{
               "type" => "image_url",
               "image_url" => %{
                 "url" => "data:image/png;base64," <> Base.encode64(@png),
                 "detail" => "low"
               }
             }

      assert authorization(conn) == ["Bearer sk-test"]
    end

    test "unset temperature and detail are absent keys, not nulls" do
      answering()

      config = config(temperature: nil, detail: nil)

      assert {:ok, _result} = call(config)
      assert_receive {:conn, conn}
      body = conn.body_params

      refute Map.has_key?(body, "temperature")

      assert [%{"content" => [_text, image]}] = body["messages"]
      refute Map.has_key?(image["image_url"], "detail")
    end

    test "api_key: nil sends no authorization header for a keyless provider" do
      answering()

      assert {:ok, _result} = call(config(api_key: nil))
      assert_receive {:conn, conn}
      assert authorization(conn) == []
    end

    test "a caller's :reqhttp_options reaches the wire, but cannot replace authorization" do
      answering()

      config =
        config(
          api_key: "sk-test",
          reqllm_options: [
            req_http_options: [headers: [{"x-test", "1"}, {"authorization", "Bearer caller"}]]
          ]
        )

      assert {:ok, _result} = call(config)
      assert_receive {:conn, conn}

      # The header a caller adds arrives...
      assert {"x-test", "1"} in conn.req_headers
      # ...but ReqLLM sets `authorization` after `:req_http_options` is spliced
      # in, so a caller cannot substitute their own bearer token. Documented, and
      # pinned here so it stays a documented limitation rather than a surprise.
      assert authorization(conn) == ["Bearer sk-test"]
    end
  end

  describe "the deadline" do
    test "a 429 is retried, and the retry can succeed" do
      counter =
        Stub.install_attempts(fn conn, attempt ->
          if attempt == 1 do
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{"error" => "slow down"})
          else
            Req.Test.json(conn, ok_body())
          end
        end)

      assert {:ok, _result} = call(config(max_retries: 1))
      assert Stub.attempts(counter) == 2
    end

    test "max_retries: 0 means exactly one request" do
      counter = always_status(429)

      assert {:error, %{reason: {:http, 429, _body}}} = call(config(max_retries: 0))
      assert Stub.attempts(counter) == 1
    end

    test "total_timeout bounds a Retry-After the server asked for" do
      # The server asks for an hour. `ReqLLM` honours `Retry-After` with no
      # ceiling of its own, so this is the whole-call deadline doing the work —
      # it is what replaces the deleted `:max_retry_delay`.
      counter = always_status(429, [{"retry-after", "3600"}])
      config = config(max_retries: 3, total_timeout: 300)

      started = System.monotonic_time(:millisecond)

      assert {:error, %{reason: {:transport, exception}}} = call(config)

      assert %ReqLLM.Error.API.Timeout{kind: :total} = exception
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert Stub.attempts(counter) == 1
    end

    test "no 5xx is retried" do
      for status <- [500, 501, 502, 503, 504, 505] do
        counter = always_status(status)

        assert {:error, %{reason: {:http, ^status, _body}}} = call(config(max_retries: 3))
        assert Stub.attempts(counter) == 1
      end
    end

    test "a transport timeout surfaces as {:transport, _} without waiting for receive_timeout" do
      counter = Stub.install(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      config = config(max_retries: 0, receive_timeout: 60_000)

      started = System.monotonic_time(:millisecond)

      assert {:error, %{reason: {:transport, _exception}}} = call(config)

      assert System.monotonic_time(:millisecond) - started < 5_000
      assert Stub.attempts(counter) == 1
    end
  end

  describe "HTTP error mapping" do
    test "a non-2xx body is head-truncated to 2048 bytes, with an ellipsis only when cut" do
      long = String.duplicate("x", 3000)

      Stub.install(fn conn ->
        Plug.Conn.put_resp_content_type(conn, "text/plain") |> Plug.Conn.send_resp(500, long)
      end)

      assert {:error, %{reason: {:http, 500, body}}} = call(config(max_retries: 0))
      assert byte_size(body) == 2048 + 3
      assert String.starts_with?(body, String.duplicate("x", 2048))
      assert String.ends_with?(body, "...")

      Stub.install(fn conn ->
        Plug.Conn.put_resp_content_type(conn, "text/plain") |> Plug.Conn.send_resp(500, "boom")
      end)

      assert {:error, %{reason: {:http, 500, "boom"}}} = call(config(max_retries: 0))
    end

    test "a truncated multibyte body is cut on a codepoint boundary" do
      # Three bytes per codepoint, so 2048 lands two bytes into one of them.
      long = String.duplicate("€", 1_000)

      Stub.install(fn conn ->
        Plug.Conn.put_resp_content_type(conn, "text/plain") |> Plug.Conn.send_resp(500, long)
      end)

      assert {:error, %{reason: {:http, 500, body}}} = call(config(max_retries: 0))

      # 682 × 3 = 2046 bytes is the largest whole-codepoint prefix of 2048, so
      # the cut backs off two bytes rather than emitting a partial codepoint.
      assert body == String.duplicate("€", 682) <> "..."
      assert String.valid?(body)
      # The reason survives a structured log pipeline, which is the point.
      assert {:ok, _json} = Jason.encode(%{reason: body})
    end

    test "a JSON error body the client decoded is re-encoded to the binary the taxonomy promises" do
      always_status(429)

      assert {:error, %{reason: {:http, 429, body}}} = call(config(max_retries: 0))
      assert is_binary(body)
      assert Jason.decode!(body) == %{"error" => "nope"}
    end

    test "a 2xx whose body is not an object is :not_an_object, never :transport" do
      # `ReqLLM` answers a non-object body by crashing its own decoder inside the
      # request task, and that crash is logged before this library maps it.
      # Captured so a deliberate row does not spray a stack trace through the
      # suite's output.
      capture_log(fn ->
        for body <- [[1, 2, 3], "a string", 42, true] do
          Stub.install(fn conn -> Req.Test.json(conn, body) end)

          assert {:error, %{reason: {:invalid_response, :not_an_object}}} = call(config())
        end
      end)
    end

    # The previous client owned the `choices` gate and answered
    # `{:invalid_response, {:choices, :empty}}` for a reply with no usable choice.
    # `ReqLLM` tolerates one and hands back an empty reply instead, so that
    # taxonomy member is no longer reachable from here: what rejects such a reply
    # is the parser downstream, which finds no content. Pinned so the
    # disappearance is a decision rather than a surprise.
    test "a 2xx object with no usable choice is an empty reply, not an error" do
      for body <- [%{}, %{"choices" => []}] do
        Stub.install(fn conn -> Req.Test.json(conn, body) end)

        assert {:ok, %{object: nil, content: "", finish_reason: nil}} = call(config())
      end
    end
  end

  describe "the result seam" do
    test "a usable reply carries the object, the content, the reason, and the usage" do
      answering()

      assert {:ok, result} = call(config())

      assert result.object == %{
               "key_colors" => [%{"hex" => "#A1B2C3"}],
               "accent_colors" => [%{"hex" => "#D4E5F6"}]
             }

      assert Jason.decode!(result.content) == result.object
      assert result.finish_reason == :stop
      assert Map.take(result.usage, [:input_tokens, :output_tokens, :total_tokens]) == @usage
    end

    test "a truncated reply reports :length rather than losing it" do
      answering(ok_body(finish_reason: "length"))

      assert {:ok, %{finish_reason: :length}} = call(config())
    end

    test "a usage-less reply normalizes to zero counts, not to nil" do
      answering(ok_body(usage: nil))

      assert {:ok, %{usage: usage}} = call(config())

      assert Map.take(usage, [:input_tokens, :output_tokens, :total_tokens]) ==
               %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

      assert usage.usage_reported == %{input: false, output: false}
    end
  end

  describe "telemetry helpers" do
    test "emit_start/1 and emit_stop/2 are span-shaped and carry counts only" do
      config = config()
      {_ref, start, stop} = emit_span(config)

      assert %{system_time: _, monotonic_time: _} = start
      assert start.model == @probe
      assert start.colors == [:key, :accent]
      assert start.counts == %{key: 3, accent: 3}
      assert start.detail == "low"
      refute Map.has_key?(start, :outcome)
      refute Map.has_key?(start, :dropped_by_field)

      # `duration` is native units, not milliseconds; both a start and a stop
      # measurement carry it.
      assert is_integer(stop.duration) and stop.duration >= 0
      assert is_integer(stop.monotonic_time)
      assert stop.max_tokens == config.max_tokens
      assert stop.input_tokens == 380
      assert stop.output_tokens == 130
      assert stop.total_tokens == 510
      assert stop.dropped == 1
      assert stop.outcome == :error
      assert stop.dropped_by_field == %{key_colors: 1}

      # No body, prompt, key, or endpoint anywhere in the metadata. `attempts` is
      # absent by design: the retry decision belongs to ReqLLM's own step now.
      for meta <- [start, stop] do
        refute Map.has_key?(meta, :api_key)
        refute Map.has_key?(meta, :prompt)
        refute Map.has_key?(meta, :body)
        refute Map.has_key?(meta, :attempts)
        refute Map.has_key?(meta, :profile)
        refute Map.has_key?(meta, :cap_key)
      end
    end

    test "a usage-less stop reports nil token counts and an empty dropped_by_field" do
      config = config()
      {_ref, _start, stop} = emit_span(config, %{usage: nil, dropped: 0, dropped_by_field: %{}})

      assert stop.input_tokens == nil
      assert stop.output_tokens == nil
      assert stop.total_tokens == nil
      assert stop.dropped == 0
      assert stop.dropped_by_field == %{}
    end
  end
end
