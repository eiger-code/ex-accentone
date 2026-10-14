defmodule Accentone.ConfigEnvTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Accentone.Config

  # The app-config and `ACCENTONE_*` rows. Both are process-global, so this
  # module is `async: false` and restores every value it touches. Per
  # ExUnit.Runner, sync modules run only after all async modules have drained,
  # so the `async: true` modules cannot observe these mutations.

  @app :accentone

  # Keep in sync with `@env_vars` in Accentone.Config.
  @vars ~w[
    ACCENTONE_MODEL ACCENTONE_API_KEY ACCENTONE_TEMPERATURE ACCENTONE_COUNT
    ACCENTONE_MAX_TOKENS ACCENTONE_DETAIL ACCENTONE_ON_INVALID_COLOR
    ACCENTONE_MAX_IMAGE_BYTES ACCENTONE_RECEIVE_TIMEOUT ACCENTONE_MAX_RETRIES
    ACCENTONE_TOTAL_TIMEOUT
  ]

  setup do
    saved_app = Application.get_all_env(@app)
    saved_vars = Map.new(@vars, &{&1, System.get_env(&1)})

    # Start each test from a clean environment so a developer's shell cannot
    # change the outcome, then put everything back on the way out.
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(@app), do: Application.delete_env(@app, key)
      for {key, value} <- saved_app, do: Application.put_env(@app, key, value)

      for {name, value} <- saved_vars do
        if value == nil, do: System.delete_env(name), else: System.put_env(name, value)
      end
    end)

    :ok
  end

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

  # The same two-liner as `config_test.exs`, where the plaintext-warning rows need
  # it; a shared helper module for this would cost more indirection than the
  # duplication does. Counting is asserted because a per-call warning that fires
  # twice is a bug, and `=~` cannot see the difference.
  defp log_occurrences(log, needle) do
    log |> String.split(needle) |> length() |> Kernel.-(1)
  end

  describe "precedence: the environment outranks app config" do
    # Every row here sets both layers, so the shadowed-app-config warning fires —
    # it is the subject of its own describe block below, and `with_log/2` keeps
    # these rows from repeating it in the suite's output.
    test "ACCENTONE_MODEL overrides an app-config model" do
      Application.put_env(@app, :model, "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.model.spec == "openai:gpt-4o"
    end

    test "ACCENTONE_TOTAL_TIMEOUT overrides an app-config total_timeout" do
      Application.put_env(@app, :total_timeout, 5_000)
      System.put_env("ACCENTONE_TOTAL_TIMEOUT", "9000")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.total_timeout == 9_000
    end

    test "ACCENTONE_DETAIL overrides an app-config detail" do
      Application.put_env(@app, :detail, "high")
      System.put_env("ACCENTONE_DETAIL", "low")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.detail == "low"
    end

    # The boundary of the rule: these four have no env var, so app config is
    # still the highest layer that can supply them.
    test "app config still owns the options the environment cannot express" do
      Application.put_env(@app, :colors, [:key])
      Application.put_env(@app, :prompt, :terse)
      Application.put_env(@app, :reqllm_options, plug: :stub)

      config = ok([])

      assert config.colors == [:key]
      assert config.prompt == :terse
      assert config.reqllm_options == [plug: :stub]
    end

    # Two accepted costs of this rank, pinned rather than left to be found.
    # `ACCENTONE_MODEL` is a string and a structured app-level model spec is a
    # map or a tuple, so the env layer can only *downgrade* one; and `:count` is
    # scalar at the env layer, so a per-role app-level form loses to it.
    test "a string ACCENTONE_MODEL shadows a structured app-config model" do
      Application.put_env(@app, :model, {:lmstudio, id: "qwen2.5-vl", base_url: "http://x/v1"})
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.model.spec == "openai:gpt-4o"
    end

    test "ACCENTONE_COUNT shadows a per-role app-config count" do
      Application.put_env(@app, :count, key: 5)
      System.put_env("ACCENTONE_COUNT", "2")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.counts == %{key: 2, accent: 2}
    end
  end

  describe "the shadowed-app-config warning" do
    # The rank is deliberate, but it is the one case where a value the application
    # author wrote is ignored in the direction a reader is least likely to expect,
    # so it is said out loud once per call — and only when the environment is what
    # actually beat it. Nothing but names reaches the log: a shadowed `:api_key`
    # is precisely where printing either value would be worst.
    test "warns once, naming the variable and the option it shadows" do
      Application.put_env(@app, :model, "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      log = capture_log(fn -> ok([]) end)

      assert log =~ "ACCENTONE_MODEL"
      assert log =~ "outranks config :accentone"
      assert log =~ ":model"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "prints neither value, which matters most for :api_key" do
      Application.put_env(@app, :api_key, "appkey")
      System.put_env("ACCENTONE_API_KEY", "envkey")

      log = capture_log(fn -> ok([]) end)

      assert log =~ "ACCENTONE_API_KEY"
      refute log =~ "appkey"
      refute log =~ "envkey"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "names every shadowed option, in @known_options order" do
      Application.put_env(@app, :temperature, 0.25)
      Application.put_env(@app, :model, "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_TEMPERATURE", "0.5")
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      log = capture_log(fn -> ok([]) end)

      # `:model` precedes `:temperature` in @known_options, so it leads the
      # message however the maps happen to iterate.
      assert log =~ "ACCENTONE_MODEL, ACCENTONE_TEMPERATURE"
      assert log_occurrences(log, "Accentone:") == 1
    end

    test "stays silent when only one layer supplies the option" do
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      log = capture_log(fn -> ok([]) end)

      refute log =~ "Accentone:"
    end

    test "stays silent when opts is what shadows the app-config value" do
      Application.put_env(@app, :model, "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o")

      log = capture_log(fn -> ok(model: "anthropic:claude-haiku-4-5") end)

      refute log =~ "Accentone:"
    end

    test "stays silent when app config is the only layer and no variable is set" do
      Application.put_env(@app, :model, "openai:gpt-4o-mini")

      log = capture_log(fn -> ok([]) end)

      refute log =~ "Accentone:"
    end
  end

  describe "precedence: a losing source cannot veto the call" do
    # Typing happens after the merge, so only the winning value is parsed. An
    # unparseable env var is the sharpest case: parsed on the way in it used to
    # fail even when `opts` supplied a good value, which made "opts is highest"
    # false in practice.
    test "opts shadows an unparseable env scalar" do
      System.put_env("ACCENTONE_TEMPERATURE", "abc")

      assert ok(temperature: 0.5).temperature == 0.5
    end

    test "an unparseable env value fails the call even when app config supplies a good one" do
      Application.put_env(@app, :temperature, 0.25)
      System.put_env("ACCENTONE_TEMPERATURE", "abc")

      assert reason([]) == {:invalid_option, :temperature, "abc"}
    end

    # The other pre-merge check that could veto a call it loses: `:api_key` is
    # validated against its tri-state in the winning layer, not on the way in.
    test "opts shadows a malformed app-config api_key" do
      Application.put_env(@app, :api_key, 123)

      assert ok(api_key: "optskey").api_key == "optskey"
    end

    test "a malformed api_key still fails when it is the winner" do
      Application.put_env(@app, :api_key, 123)

      assert reason([]) == {:invalid_option, :api_key, 123}
    end

    # Names are checked per source before the merge, deliberately: a typo is a
    # claim about the option surface, not a value, so `opts` does not hide it.
    test "an unknown app-config name is still fatal when opts supplies the value" do
      Application.put_env(@app, :color, [:key])

      assert reason(temperature: 0.5) == {:invalid_option, :color, [:key]}
    end

    test "an unknown app-config name is still fatal when the environment supplies every value" do
      Application.put_env(@app, :color, [:key])
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_TEMPERATURE", "0.5")

      assert reason([]) == {:invalid_option, :color, [:key]}
    end
  end

  describe "precedence: the environment outranks the defaults" do
    test "each scalar env var is parsed to its option's type" do
      System.put_env("ACCENTONE_MODEL", "openai:gpt-4o-mini")
      System.put_env("ACCENTONE_TEMPERATURE", "0.7")
      System.put_env("ACCENTONE_COUNT", "2")
      System.put_env("ACCENTONE_MAX_TOKENS", "777")
      System.put_env("ACCENTONE_DETAIL", "high")
      System.put_env("ACCENTONE_ON_INVALID_COLOR", "drop")
      System.put_env("ACCENTONE_MAX_IMAGE_BYTES", "500")
      System.put_env("ACCENTONE_RECEIVE_TIMEOUT", "1000")
      System.put_env("ACCENTONE_MAX_RETRIES", "0")
      System.put_env("ACCENTONE_TOTAL_TIMEOUT", "250")

      config = ok([])

      assert config.model.spec == "openai:gpt-4o-mini"
      assert config.temperature == 0.7
      assert config.counts == %{key: 2, accent: 2}
      assert config.max_tokens == 777
      assert config.detail == "high"
      assert config.on_invalid_color == :drop
      assert config.max_image_bytes == 500
      assert config.receive_timeout == 1000
      assert config.max_retries == 0
      assert config.total_timeout == 250
    end

    test "ACCENTONE_TEMPERATURE=1 parses as the float 1.0" do
      System.put_env("ACCENTONE_TEMPERATURE", "1")

      assert ok([]).temperature == 1.0
    end

    test "ACCENTONE_COUNT=2 is the uniform form" do
      System.put_env("ACCENTONE_COUNT", "2")

      assert ok([]).counts == %{key: 2, accent: 2}
    end

    test "an unrecognised ACCENTONE_* variable is ignored, not fatal" do
      System.put_env("ACCENTONE_NOPE", "1")

      assert ok([]).model.spec == "openai:gpt-4o"
    end
  end

  describe "env parsing failures" do
    test "an unparseable scalar is {:invalid_option, name, raw}" do
      rows = [
        {"ACCENTONE_TEMPERATURE", :temperature, "abc"},
        {"ACCENTONE_TEMPERATURE", :temperature, "0.5x"},
        {"ACCENTONE_COUNT", :count, "2.5"},
        {"ACCENTONE_COUNT", :count, "x"},
        {"ACCENTONE_MAX_TOKENS", :max_tokens, "x"},
        {"ACCENTONE_DETAIL", :detail, "bogus"},
        {"ACCENTONE_ON_INVALID_COLOR", :on_invalid_color, "bogus"},
        {"ACCENTONE_MAX_IMAGE_BYTES", :max_image_bytes, "x"},
        {"ACCENTONE_RECEIVE_TIMEOUT", :receive_timeout, "x"},
        {"ACCENTONE_MAX_RETRIES", :max_retries, "x"},
        {"ACCENTONE_TOTAL_TIMEOUT", :total_timeout, "x"}
      ]

      for {var, name, raw} <- rows do
        System.put_env(var, raw)
        assert reason([]) == {:invalid_option, name, raw}, "#{var}=#{raw}"
        System.delete_env(var)
      end
    end

    test "there is no env spelling for total_timeout: nil" do
      System.put_env("ACCENTONE_TOTAL_TIMEOUT", "nil")

      assert reason([]) == {:invalid_option, :total_timeout, "nil"}
    end

    # A bare model name is not a spec: it names no provider. An *empty* env value
    # is a different thing — it counts as not supplied at all, which the sibling
    # describe covers.
    test "an env model that is not a spec is rejected like any other model" do
      for raw <- ["llava", "openai:", "nosuchprovider:x"] do
        System.put_env("ACCENTONE_MODEL", raw)
        assert reason([]) == {:invalid_option, :model, raw}, raw
        System.delete_env("ACCENTONE_MODEL")
      end
    end
  end

  describe "an empty env value is not supplied" do
    test "each empty scalar falls back to its default" do
      System.put_env("ACCENTONE_MODEL", "")
      System.put_env("ACCENTONE_COUNT", "")
      System.put_env("ACCENTONE_TEMPERATURE", "")
      System.put_env("ACCENTONE_DETAIL", "")

      config = ok([])

      assert config.model.spec == "openai:gpt-4o"
      assert config.counts == %{key: 3, accent: 3}
      assert config.temperature == 0.0
      assert config.detail == "low"
    end

    test "an empty ACCENTONE_API_KEY with no app-config key is missing, not none" do
      Application.delete_env(@app, :api_key)
      System.put_env("ACCENTONE_API_KEY", "")

      assert reason([]) == :missing_api_key
    end
  end

  describe "api_key tri-state (app config and env)" do
    test "no source supplies a key, so a key-requiring provider is unset" do
      Application.delete_env(@app, :api_key)

      assert reason([]) == :missing_api_key
    end

    # A keyless provider needs no credential, so nothing has to be configured at
    # all — `model: "ollama:llava"` in app config is a complete setup.
    test "a keyless provider resolves with no key anywhere" do
      Application.delete_env(@app, :api_key)
      Application.put_env(@app, :model, "ollama:llava")

      assert ok([]).api_key == nil
    end

    test "an untagged nil from app config is unset, not no-credential" do
      Application.put_env(@app, :api_key, nil)

      assert reason([]) == :missing_api_key
    end

    test "an env key is used when app config supplies none" do
      Application.delete_env(@app, :api_key)
      System.put_env("ACCENTONE_API_KEY", "envkey")

      assert ok([]).api_key == "envkey"
    end

    # The other side of the tri-state: an app-level `nil` means *unset*, so it
    # no longer suppresses a credential the environment supplies. That is a
    # documented cost of the rank — `opts api_key: nil` remains the way to
    # assert "send no credential", and only a keyless provider can honour it.
    test "an env key outranks an app-config nil" do
      Application.put_env(@app, :api_key, nil)
      System.put_env("ACCENTONE_API_KEY", "envkey")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.api_key == "envkey"
    end

    test "an env key outranks an app-config key" do
      Application.put_env(@app, :api_key, "appkey")
      System.put_env("ACCENTONE_API_KEY", "envkey")

      {config, _log} = with_log(fn -> ok([]) end)

      assert config.api_key == "envkey"
    end

    test "opts api_key outranks an app-config nil" do
      Application.put_env(@app, :api_key, nil)

      assert ok(api_key: "optskey").api_key == "optskey"
    end

    test "opts api_key outranks an env key" do
      System.put_env("ACCENTONE_API_KEY", "envkey")

      assert ok(api_key: "optskey").api_key == "optskey"
    end

    # The documented tri-state, from the other side: `nil` in `opts` means "send
    # no credential", and a provider that needs one cannot honour that.
    test "an explicit nil in opts is rejected on a key-requiring provider" do
      assert reason(api_key: nil) == {:invalid_option, :api_key, nil}
    end
  end

  describe "unknown app-config names" do
    test "an unrecognised app-config key is itself an error" do
      Application.put_env(@app, :color, [:key])

      assert reason([]) == {:invalid_option, :color, [:key]}
    end

    test "top_p in app config is an error" do
      Application.put_env(@app, :top_p, 0.9)

      assert reason([]) == {:invalid_option, :top_p, 0.9}
    end
  end
end
