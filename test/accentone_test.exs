defmodule AccentoneTest do
  use ExUnit.Case

  alias Accentone.Color
  alias Accentone.Error
  alias Accentone.Fixtures
  alias Accentone.Palette
  alias Accentone.Stub
  alias Accentone.TelemetryCapture

  # Pipeline rows: the public `analyze/1,2` / `analyze!/1,2` surface and the
  # `with` chain behind it (config → load/detect → prompt → call → parse →
  # palette), driven end to end through `Req.Test`. The two
  # claims that only the assembled pipeline can make are here:
  #
  #   * the zero-call guarantee — every pre-flight failure returns without a
  #     request, asserted with a stub counter rather than only an error match;
  #   * the telemetry span — started only once a request exists, stopped on
  #     every post-request outcome.
  #
  # This module is `async: false` because one row (`:missing_api_key`) mutates
  # app config; it restores it on exit. Everything else here is stub-driven,
  # including the spawned-`Task` row, which needs `Req.Test.allow/3` because a
  # stub installed in the test process is not visible to a process the test
  # starts.

  @png Fixtures.png()

  # An inline `:lmstudio` spec on purpose: that is a **chat-surface** provider, so
  # `Stub.success_body/2`'s chat-shaped envelope decodes properly. `ReqLLM` routes
  # the default `"openai:gpt-4o"` to `/v1/responses`, where the same envelope
  # decodes to an empty message. The endpoint is loopback so nothing here logs the
  # plaintext warning, and the id doubles as this file's telemetry marker.
  @model %{provider: :lmstudio, id: "pipeline-probe", base_url: "http://127.0.0.1:1234/v1"}
  @probe "lmstudio:pipeline-probe"

  defp stub_options(opts \\ []) do
    reqllm_options = Keyword.get(opts, :reqllm_options, [])

    # The caller's Req options merge *into* the stub's: `Keyword.get/3` takes the
    # first hit, so a second `:req_http_options` entry would drop the stub.
    req_http_options =
      Keyword.merge([plug: Stub.plug()], Keyword.get(reqllm_options, :req_http_options, []))

    opts
    |> Keyword.put_new(:model, @model)
    |> Keyword.put(
      :reqllm_options,
      Keyword.put(reqllm_options, :req_http_options, req_http_options)
    )
  end

  # The connection goes to the **test** process, not to `self()` inside this
  # closure: a finite `:total_timeout` makes `ReqLLM` run the request in its own
  # task, so `self()` in the plug handler is that task's pid.
  defp answering(body \\ nil) do
    test = self()

    Stub.install(fn conn ->
      send(test, {:conn, conn})
      Req.Test.json(conn, body || Stub.success_body(key: "#A1B2C3", accent: "#D4E5F6"))
    end)
  end

  defp attach do
    ref =
      TelemetryCapture.attach(
        [
          [:accentone, :analyze, :start],
          [:accentone, :analyze, :stop]
        ],
        filter: &(&1.model == @probe)
      )

    on_exit(fn -> TelemetryCapture.detach(ref) end)
    ref
  end

  describe "analyze/2 end to end" do
    test "assembles a palette for a non-uniform count and a multi-role request" do
      answering(
        Stub.success_body(
          key: "#A1B2C3",
          key: "#111111",
          accent: "#D4E5F6",
          muted: "#222222"
        )
      )

      opts =
        stub_options(
          colors: [:key, :accent, :muted],
          count: [key: 1, accent: 3, muted: 3]
        )

      assert {:ok, %Palette{} = palette} = Accentone.analyze({:bytes, @png}, opts)

      assert Palette.roles(palette) == [:key, :accent, :muted]
      # `count: [key: 1]` truncates key to its first entry; each role keeps its
      # own list, and the caller's `colors:` order is preserved.
      assert Palette.get(palette, :key) == [%Color{hex: "#A1B2C3", confidence: nil}]
      assert Palette.get(palette, :accent) == [%Color{hex: "#D4E5F6", confidence: nil}]
      assert Palette.get(palette, :muted) == [%Color{hex: "#222222", confidence: nil}]

      # Unrequested roles are `nil`, never `[]`.
      assert palette.background_colors == nil
      assert palette.surface_colors == nil
      assert palette.highlight_colors == nil
    end

    test "a requested role the model omitted is [] and an unrequested one is nil" do
      answering(Stub.success_body(key: "#A1B2C3"))

      assert {:ok, palette} = Accentone.analyze({:bytes, @png}, stub_options())

      assert palette.key_colors == [%Color{hex: "#A1B2C3", confidence: nil}]
      assert palette.accent_colors == []
      assert palette.muted_colors == nil
    end
  end

  describe "analyze!/2" do
    test "returns the bare palette on success and raises with the twin's reason" do
      answering()
      assert %Palette{} = Accentone.analyze!({:bytes, @png}, stub_options())

      Stub.install(fn conn -> Req.Test.json(conn, %{"choices" => []}) end)
      opts = stub_options()

      assert {:error, reason} = Accentone.analyze({:bytes, @png}, opts)

      error = assert_raise Error, fn -> Accentone.analyze!({:bytes, @png}, opts) end
      assert error.reason == reason
      # A reply with no usable choice is an empty reply rather than a client-layer
      # error now — `ReqLLM` owns that gate — so what rejects it is the parser
      # finding no object to read.
      assert reason == {:invalid_json, :no_object}
      assert Exception.message(error) =~ "no JSON object"
    end
  end

  describe "the zero-call pre-flight table" do
    test "config, detection, size, and prompt failures make no request" do
      counter =
        Stub.install(fn conn -> Req.Test.json(conn, Stub.success_body(key: "#A1B2C3")) end)

      rows = [
        {123, [], {:invalid_option, :input, 123}},
        {{:bytes, @png}, [top_p: 0.9], {:invalid_option, :top_p, 0.9}},
        {{:bytes, @png}, [color: [:key]], {:invalid_option, :color, [:key]}},
        {{:bytes, Fixtures.no_signature()}, [], :not_an_image},
        {{:bytes, @png}, [max_image_bytes: 10], {:image_too_large, byte_size(@png)}},
        {{:bytes, @png}, [prompt: "no role keys here"],
         {:invalid_option, :prompt, {:missing_role_key, :key_colors}}}
      ]

      for {input, opts, expected} <- rows do
        assert {:error, ^expected} = Accentone.analyze(input, stub_options(opts))
      end

      Stub.verify_no_call!(counter)
    end

    test ":missing_api_key makes no request" do
      counter =
        Stub.install(fn conn -> Req.Test.json(conn, Stub.success_body(key: "#A1B2C3")) end)

      saved = Application.get_env(:accentone, :api_key)
      Application.put_env(:accentone, :api_key, nil)
      on_exit(fn -> Application.put_env(:accentone, :api_key, saved) end)

      # A key-requiring provider explicitly: the stub's own default model is
      # keyless, and `analyze/2` resolving with no key at all is the correct
      # outcome there rather than a failure.
      assert {:error, :missing_api_key} =
               Accentone.analyze({:bytes, @png}, stub_options(model: "openai:gpt-4o"))

      Stub.verify_no_call!(counter)
    end
  end

  describe "telemetry" do
    test "start/stop pair on success, with counts and no payload" do
      answering()
      ref = attach()

      assert {:ok, %Palette{}} = Accentone.analyze({:bytes, @png}, stub_options(model: @probe))

      assert_receive {^ref, [:accentone, :analyze, :start], start_measurements, start_meta}
      assert_receive {^ref, [:accentone, :analyze, :stop], stop_measurements, stop_meta}

      assert %{system_time: _, monotonic_time: _} = start_measurements
      assert start_meta.model == @probe
      assert start_meta.colors == [:key, :accent]
      assert start_meta.counts == %{key: 3, accent: 3}
      assert start_meta.detail == "low"
      refute Map.has_key?(start_meta, :outcome)
      refute Map.has_key?(start_meta, :dropped_by_field)

      # `duration` is native time units, and both measurements carry a
      # `monotonic_time`.
      assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0
      assert is_integer(stop_measurements.monotonic_time)
      assert stop_measurements.max_tokens == 256
      assert stop_measurements.input_tokens == 380
      assert stop_measurements.output_tokens == 130
      assert stop_measurements.total_tokens == 510
      assert stop_measurements.dropped == 0

      assert stop_meta.outcome == :ok
      assert stop_meta.dropped_by_field == %{}
      assert Map.drop(stop_meta, [:outcome, :dropped_by_field]) == start_meta

      for meta <- [start_meta, stop_meta] do
        refute Map.has_key?(meta, :api_key)
        refute Map.has_key?(meta, :url)
        refute Map.has_key?(meta, :prompt)
        refute Map.has_key?(meta, :body)
      end
    end

    test "a post-request failure still emits start/stop with outcome :error" do
      Stub.install(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      ref = attach()

      assert {:error, {:http, 500, _}} =
               Accentone.analyze(
                 {:bytes, @png},
                 stub_options(model: @probe, max_retries: 0)
               )

      assert_receive {^ref, [:accentone, :analyze, :start], _, _}
      assert_receive {^ref, [:accentone, :analyze, :stop], measurements, meta}
      assert meta.outcome == :error
      assert meta.dropped_by_field == %{}
      assert measurements.input_tokens == nil
      assert measurements.dropped == 0
    end

    test "a parse failure keeps the provider usage on the stop" do
      Stub.install(fn conn ->
        Req.Test.json(conn, Stub.success_body([], finish_reason: "length"))
      end)

      ref = attach()

      assert {:error, {:truncated, :length}} =
               Accentone.analyze({:bytes, @png}, stub_options(model: @probe))

      assert_receive {^ref, [:accentone, :analyze, :start], _, _}
      assert_receive {^ref, [:accentone, :analyze, :stop], measurements, meta}
      assert meta.outcome == :error
      assert measurements.input_tokens == 380
    end

    test ":drop leniency is visible in the stop measurements" do
      Stub.install(fn conn ->
        Req.Test.json(conn, Stub.success_body(key: "#NOTHEX", accent: "#D4E5F6"))
      end)

      ref = attach()

      assert {:ok, %Palette{}} =
               Accentone.analyze(
                 {:bytes, @png},
                 stub_options(model: @probe, on_invalid_color: :drop)
               )

      assert_receive {^ref, [:accentone, :analyze, :start], _, _}
      assert_receive {^ref, [:accentone, :analyze, :stop], measurements, meta}
      assert meta.outcome == :ok
      assert meta.dropped_by_field == %{key_colors: 1}
      assert measurements.dropped == 1
    end

    test "pre-flight failures emit nothing at all" do
      Stub.install(fn conn -> Req.Test.json(conn, Stub.success_body(key: "#A1B2C3")) end)
      ref = attach()

      assert {:error, :not_an_image} =
               Accentone.analyze({:bytes, Fixtures.no_signature()}, stub_options(model: @probe))

      assert {:error, {:invalid_option, :prompt, {:missing_role_key, :key_colors}}} =
               Accentone.analyze(
                 {:bytes, @png},
                 stub_options(model: @probe, prompt: "nothing")
               )

      refute_received {^ref, _, _, _}
    end
  end

  describe "a Task caller" do
    # The recommended caller shape runs `analyze/2` in a spawned `Task` rather
    # than awaiting a synchronous call on a request path. The consequence is
    # pinned here: a stub installed with `Req.Test.stub/2` lives in
    # the *installing* process's dictionary, so the spawned task has to be
    # handed access with `Req.Test.allow/3` or the request has no stub at all.
    test "Req.Test.allow/3 lets a spawned Task reach the per-test stub" do
      counter =
        Stub.install(fn conn -> Req.Test.json(conn, Stub.success_body(key: "#A1B2C3")) end)

      owner = self()

      task =
        Task.async(fn ->
          # Without this line the task's `Req` looks like a real caller and the
          # stub is invisible; with it, the request is served by the stub.
          Req.Test.allow(Stub, owner, self())
          Accentone.analyze({:bytes, @png}, stub_options())
        end)

      assert {:ok, %Palette{}} = Task.await(task)
      assert Stub.attempts(counter) == 1
    end
  end
end
