defmodule Accentone.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Accentone.Config
  alias Accentone.Model

  # The option-validation table, the `:count`/derived-cap table, and the
  # plaintext-warning matrix, all driven from `opts` alone. The tests that need to
  # mutate process-global state (app config and `ACCENTONE_*`) live in
  # `config_env_test.exs`, which is `async: false`.

  # A keyless provider (`:lmstudio` suppresses the `authorization` header), on
  # loopback so nothing in this file logs the plaintext warning by accident.
  @keyless %{provider: :lmstudio, id: "local", base_url: "http://127.0.0.1:1234/v1"}
  @lan %{provider: :lmstudio, id: "local", base_url: "http://example.com/v1"}
  @tls %{provider: :lmstudio, id: "local", base_url: "https://example.com/v1"}

  defp ok(opts) do
    case Config.resolve(opts) do
      {:ok, config} -> config
      {:error, reason} -> flunk("expected a resolved config, got #{inspect(reason)}")
    end
  end

  defp reason(opts) do
    case Config.resolve(opts) do
      {:error, reason} -> reason
      {:ok, config} -> flunk("expected an error, got #{inspect(config)}")
    end
  end

  describe "library defaults" do
    test "resolve/0 fills every field from the defaults" do
      config = ok([])

      assert %Config{} = config
      assert %Model{} = config.model
      assert Model.label(config.model) == "openai:gpt-4o"
      assert config.model.provider == :openai
      assert config.model.base_url == "https://api.openai.com/v1"
      assert config.temperature == 0.0
      assert config.colors == [:key, :accent]
      assert config.counts == %{key: 3, accent: 3}
      assert config.max_tokens == 256
      assert config.detail == "low"
      assert config.prompt == :default
      assert config.on_invalid_color == :error
      assert config.max_image_bytes == 10_000_000
      assert config.receive_timeout == 60_000
      assert config.max_retries == 1
      assert config.total_timeout == 180_000
      assert config.reqllm_options == []
      # `api_key: "test"` is set by test/test_helper.exs.
      assert config.api_key == "test"
    end

    test "opts override every default" do
      config =
        ok(
          model: "openai:gpt-4o-mini",
          temperature: 0.5,
          detail: "high",
          prompt: :terse,
          on_invalid_color: :drop,
          max_tokens: 1024,
          max_image_bytes: 1234,
          receive_timeout: 5_000,
          max_retries: 0,
          total_timeout: nil,
          reqllm_options: [receive_timeout: 1]
        )

      assert config.model.spec == "openai:gpt-4o-mini"
      assert config.temperature == 0.5
      assert config.detail == "high"
      assert config.prompt == :terse
      assert config.on_invalid_color == :drop
      assert config.max_tokens == 1024
      assert config.max_image_bytes == 1234
      assert config.receive_timeout == 5_000
      assert config.max_retries == 0
      assert config.total_timeout == nil
      assert config.reqllm_options == [receive_timeout: 1]
    end
  end

  describe "unknown option names" do
    test "an unrecognised opts key is itself an error" do
      assert reason(color: [:key]) == {:invalid_option, :color, [:key]}
      assert reason(top_p: 0.9) == {:invalid_option, :top_p, 0.9}
      assert reason(cap: :max_tokens) == {:invalid_option, :cap, :max_tokens}
      assert reason(column: 1) == {:invalid_option, :column, 1}
    end

    test "a bare unknown atom is an error" do
      assert reason([:shadow]) == {:invalid_option, :shadow, nil}
    end

    test "non-keyword opts fail matchably rather than raising" do
      assert reason(%{colors: [:key]}) == {:invalid_option, :opts, %{colors: [:key]}}
      assert reason("colors") == {:invalid_option, :opts, "colors"}
    end
  end

  describe "api_key tri-state (opts)" do
    test "a non-empty binary is the bearer key" do
      assert ok(api_key: "secret").api_key == "secret"
    end

    test "an explicit nil in opts means send no credential, on a keyless provider" do
      config = ok(api_key: nil, model: @keyless)

      assert config.api_key == nil
      assert config.model.provider == :lmstudio
    end

    # Only the adapters that suppress the `authorization` header can honour this,
    # so anywhere else it has to be a pre-flight error rather than an exception
    # raised from inside `ReqLLM.Keys.get!/2`.
    test "an explicit nil is rejected for a provider that requires a key" do
      for model <- ["openai:gpt-4o", "anthropic:claude-3-5-sonnet", "openai:gpt-4o-mini"] do
        assert reason(api_key: nil, model: model) == {:invalid_option, :api_key, nil}
      end
    end

    test "an empty string and a non-binary are invalid" do
      assert reason(api_key: "") == {:invalid_option, :api_key, ""}
      assert reason(api_key: 123) == {:invalid_option, :api_key, 123}
      assert reason(api_key: [:k]) == {:invalid_option, :api_key, [:k]}
    end
  end

  describe "colors" do
    test "any non-empty distinct subset of the six roles, in the caller's order" do
      config = ok(colors: [:muted, :key, :highlight])

      assert config.colors == [:muted, :key, :highlight]
      assert config.counts == %{muted: 3, key: 3, highlight: 3}
    end

    test "empty, duplicated, unknown, and non-atom lists are errors" do
      for bad <- [[], [:key, :key], [:shadow], [:key, "accent"], [:key, :accent, :key]] do
        assert reason(colors: bad) == {:invalid_option, :colors, bad}
      end

      assert reason(colors: :key) == {:invalid_option, :colors, :key}
      assert reason(colors: nil) == {:invalid_option, :colors, nil}
    end
  end

  describe "count" do
    test "a uniform integer in 1..10 applies to every requested role" do
      config = ok(colors: [:key, :accent, :muted], count: 2)

      assert config.counts == %{key: 2, accent: 2, muted: 2}
    end

    test "a keyword list names requested roles; unnamed requested roles default to 3" do
      assert ok(count: [key: 1, accent: 3]).counts == %{key: 1, accent: 3}
      assert ok(count: [key: 1]).counts == %{key: 1, accent: 3}

      assert ok(colors: [:key, :accent, :muted], count: [key: 1, muted: 5]).counts ==
               %{key: 1, accent: 3, muted: 5}
    end

    test "the invalid rows are all {:invalid_option, :count, value}" do
      invalid = [0, 11, -1, 2.0, "3", nil, [], %{}, [key: 0], [key: 11], [key: "3"]]

      for bad <- invalid do
        assert reason(count: bad) == {:invalid_option, :count, bad}
      end

      # A role that was not requested, a duplicate key, and a non-keyword list.
      assert reason(count: [shadow: 1]) == {:invalid_option, :count, [shadow: 1]}
      assert reason(count: [key: 1, key: 2]) == {:invalid_option, :count, [key: 1, key: 2]}
      assert reason(count: [{"key", 1}]) == {:invalid_option, :count, [{"key", 1}]}
    end
  end

  describe "derived max_tokens" do
    test "is 64 + 24 * sum(counts), floored at 256" do
      # key + accent at the default 3: 64 + 24 * 6 = 208 -> 256.
      assert ok([]).max_tokens == 256

      # all six roles at 3: 64 + 24 * 18 = 496.
      assert ok(colors: [:key, :accent, :background, :surface, :muted, :highlight]).max_tokens ==
               496

      # key 1 + accent 3 + muted 3: 64 + 24 * 7 = 232 -> 256.
      assert ok(colors: [:key, :accent, :muted], count: [key: 1, accent: 3, muted: 3]).max_tokens ==
               256

      # 2 roles at 10: 64 + 24 * 20 = 544.
      assert ok(count: 10).max_tokens == 544
    end

    test "an explicit max_tokens overrides the derivation" do
      assert ok(count: 10, max_tokens: 1024).max_tokens == 1024
    end

    test "a non-positive or non-integer max_tokens is an error" do
      for bad <- [0, -1, "1024", 1.5, nil] do
        assert reason(max_tokens: bad) == {:invalid_option, :max_tokens, bad}
      end
    end
  end

  describe "temperature" do
    test "nil and numbers in 0.0..2.0 are accepted" do
      assert ok(temperature: nil).temperature == nil
      assert ok(temperature: 0).temperature == 0
      assert ok(temperature: 0.0).temperature == 0.0
      assert ok(temperature: 1).temperature == 1
      assert ok(temperature: 2.0).temperature == 2.0
    end

    test "out-of-range and non-numeric values are errors" do
      for bad <- [-0.1, 2.1, "0.5", true, :hot, []] do
        assert reason(temperature: bad) == {:invalid_option, :temperature, bad}
      end
    end
  end

  describe "detail" do
    test "accepts nil and the three provider hints" do
      assert ok(detail: nil).detail == nil
      assert ok(detail: "low").detail == "low"
      assert ok(detail: "high").detail == "high"
      assert ok(detail: "auto").detail == "auto"
    end

    test "rejects anything else" do
      for bad <- ["medium", :low, 1, "LOW"] do
        assert reason(detail: bad) == {:invalid_option, :detail, bad}
      end
    end
  end

  describe "prompt" do
    test "accepts :default, :terse, and a non-empty binary" do
      assert ok(prompt: :default).prompt == :default
      assert ok(prompt: :terse).prompt == :terse
      assert ok(prompt: "return key_colors").prompt == "return key_colors"
    end

    test "rejects an empty binary and anything that is not a mode or binary" do
      for bad <- ["", nil, :short, 1, ["x"]] do
        assert reason(prompt: bad) == {:invalid_option, :prompt, bad}
      end
    end
  end

  describe "on_invalid_color" do
    test "accepts the two leniency modes only" do
      assert ok(on_invalid_color: :error).on_invalid_color == :error
      assert ok(on_invalid_color: :drop).on_invalid_color == :drop
    end

    test "rejects anything else" do
      for bad <- [:ignore, "drop", nil, 0] do
        assert reason(on_invalid_color: bad) == {:invalid_option, :on_invalid_color, bad}
      end
    end
  end

  describe "model" do
    test "accepts the three spec shapes and reports the provider" do
      for {spec, provider} <- [
            {"openai:gpt-4o", :openai},
            {{:lmstudio, id: "local", base_url: "http://127.0.0.1:1234/v1"}, :lmstudio},
            {%{provider: :ollama, id: "llava"}, :ollama}
          ] do
        assert ok(model: spec).model.provider == provider
      end
    end

    test "resolves the provider's own endpoint when the spec carries none" do
      assert ok(model: "openai:gpt-4o").model.base_url == "https://api.openai.com/v1"
      assert ok(model: "ollama:llava").model.base_url == "http://localhost:11434/v1"
    end

    # `ReqLLM` logs "Using unverified model" on every call for an id the catalog
    # does not know, and that is the advertised local path — so an uncataloged id
    # is rewritten to the inline form, which says the caller meant it.
    test "an uncataloged id is rewritten to the inline form" do
      assert ok(model: "ollama:llava").model.spec == %{provider: :ollama, id: "llava"}
    end

    # A cataloged spec keeps the shape the caller wrote, because the inline form
    # drops `capabilities` and `extra.wire` — the latter decides whether OpenAI is
    # called on `/v1/responses` or `/v1/chat/completions`.
    test "a cataloged spec is passed through exactly as written" do
      assert ok(model: "openai:gpt-4o").model.spec == "openai:gpt-4o"
      assert ok(model: {:openai, id: "gpt-4o"}).model.spec == {:openai, id: "gpt-4o"}
    end

    test "rejects a spec naming no provider, no model, or an unknown provider" do
      for bad <- ["", nil, 42, "openai:", "nosuchprovider:model", %{id: "x"}, [:a]] do
        assert reason(model: bad) == {:invalid_option, :model, bad}
      end
    end
  end

  describe "max_image_bytes and receive_timeout" do
    test "accept positive integers" do
      assert ok(max_image_bytes: 1).max_image_bytes == 1
      assert ok(receive_timeout: 1).receive_timeout == 1
    end

    test "reject zero, negatives, and non-integers" do
      for bad <- [0, -1, "1000", 1.0, nil] do
        assert reason(max_image_bytes: bad) == {:invalid_option, :max_image_bytes, bad}
        assert reason(receive_timeout: bad) == {:invalid_option, :receive_timeout, bad}
      end
    end
  end

  describe "max_retries and total_timeout" do
    test "accept the documented ranges" do
      assert ok(max_retries: 0).max_retries == 0
      assert ok(max_retries: 5).max_retries == 5
      assert ok(total_timeout: nil).total_timeout == nil
      assert ok(total_timeout: 1).total_timeout == 1
      assert ok(total_timeout: 180_000).total_timeout == 180_000
    end

    test "reject negatives, floats, and non-integers" do
      for bad <- [-1, 1.0, "1", nil] do
        assert reason(max_retries: bad) == {:invalid_option, :max_retries, bad}
      end

      # `nil` is the "no deadline" spelling; zero is not a deadline at all.
      for bad <- [0, -1, 1.0, "1", :forever] do
        assert reason(total_timeout: bad) == {:invalid_option, :total_timeout, bad}
      end
    end
  end

  describe "reqllm_options" do
    test "accepts keyword lists, including the empty one" do
      assert ok(reqllm_options: []).reqllm_options == []

      assert ok(reqllm_options: [receive_timeout: 1, req_http_options: [plug: :stub]]).reqllm_options ==
               [receive_timeout: 1, req_http_options: [plug: :stub]]
    end

    test "rejects non-keyword lists and non-lists" do
      assert reason(reqllm_options: %{}) == {:invalid_option, :reqllm_options, %{}}
      assert reason(reqllm_options: [1]) == {:invalid_option, :reqllm_options, [1]}

      assert reason(reqllm_options: [{"plug", :stub}]) ==
               {:invalid_option, :reqllm_options, [{"plug", :stub}]}

      assert reason(reqllm_options: nil) == {:invalid_option, :reqllm_options, nil}
    end
  end

  describe "the plaintext warning" do
    # Warned about, not rejected — a local endpoint needs http://. What is warned
    # about is the *payload*: the image and the prompt travel in the clear on
    # every request, so a keyless endpoint is warned about exactly as loudly as a
    # keyed one. Only the *wording* depends on the key — the bearer-token clause
    # appears when a credential is on the wire and not otherwise — and that is
    # the pair of positive rows below. The endpoint comes from the resolved model
    # spec rather than a `:url`, so this covers the whole path from spec to
    # warning.
    #
    # The negative rows below match on the `Accentone:` marker rather than
    # asserting an empty log. The suite is `async: true`, and another test's
    # background task — `ReqLLM` logging a decoder crash it is about to map — can
    # log into whichever capture window happens to be open, so `log == ""`
    # asserts a property of the whole VM instead of the subject under test.
    test "warns once for an http endpoint with a key on a non-loopback host" do
      log = capture_log(fn -> ok(model: @lan, api_key: "k") end)

      assert log =~ "example.com"
      assert log =~ "plaintext"
      assert log =~ "bearer token"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "warns for a keyless endpoint too, and claims no credential" do
      log = capture_log(fn -> ok(model: @lan, api_key: nil) end)

      assert log =~ "example.com"
      assert log =~ "no credential"
      refute log =~ "bearer token"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "names the host for a LAN address too" do
      lan = %{provider: :lmstudio, id: "local", base_url: "http://192.168.1.5:8080/v1"}
      log = capture_log(fn -> ok(model: lan, api_key: "k") end)

      assert log =~ "192.168.1.5"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "does not warn for loopback hosts, keyed or keyless" do
      for url <- [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://127.5.5.5:11434/v1",
            "http://[::1]:11434/v1"
          ],
          api_key <- ["k", nil] do
        spec = %{provider: :lmstudio, id: "local", base_url: url}

        log = capture_log(fn -> ok(model: spec, api_key: api_key) end)

        refute log =~ "Accentone:",
               "expected no warning for #{url} with key #{inspect(api_key)}, got: #{log}"
      end
    end

    test "does not warn for a provider's own loopback default" do
      log = capture_log(fn -> ok(model: "ollama:llava", api_key: nil) end)
      refute log =~ "Accentone:"
    end

    test "does not warn for https, keyed or keyless" do
      for api_key <- ["k", nil] do
        log = capture_log(fn -> ok(model: @tls, api_key: api_key) end)

        refute log =~ "Accentone:"
      end
    end

    test "does not warn for an http endpoint with no host" do
      spec = %{provider: :lmstudio, id: "local", base_url: "http:///v1"}
      log = capture_log(fn -> ok(model: spec, api_key: "k") end)

      refute log =~ "Accentone:"
    end
  end

  defp log_occurrences(log, needle) do
    log |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
