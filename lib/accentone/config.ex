defmodule Accentone.Config do
  @moduledoc false

  # Resolve `opts` → `config :accentone` → `ACCENTONE_*` → library default,
  # highest first, into the plain struct `analyze/2` reads. All validation
  # happens here, before any I/O, so a typo is a cheap `{:invalid_option, ...}`
  # rather than a paid call that fails as a confusing `:no_colors`.
  #
  # There is no `:profile` and no `:url`. An endpoint used to be one decision
  # spread across five options — endpoint, model name, credential style, image
  # detail, and which spelling of the output cap the server accepts — and a
  # profile named the combination. `ReqLLM` owns each of those per provider now,
  # so the combination is written the way that library writes it: a model spec in
  # `:model`, with `:base_url` inside the spec when the endpoint is somewhere
  # other than the provider's default. `Accentone.Model` is where that spec is
  # read; this module only decides that it is well-formed.
  #
  # Two things below are easy to get subtly wrong and are therefore spelled out:
  #
  #   * `:api_key`'s tri-state survives with its meaning intact — a `nil` written
  #     in `opts` is "deliberately send no credential", a `nil` from app config is
  #     *unset* — but the credential-less request is now a **validated
  #     capability** rather than an assumption. Only the two adapters that
  #     suppress the `authorization` header can send no credential, so
  #     `api_key: nil` is a pre-flight error everywhere else (doc 10's D4).
  #   * `:model` is resolved *here*, not at call time, so an unknown provider is
  #     the same class of cheap pre-flight error as any other typo.

  alias Accentone.Model
  alias Accentone.Prompt

  require Logger

  # The two providers whose `ReqLLM` adapter suppresses the `authorization`
  # header when nothing resolves: `LMStudio`'s `put_auth(request, nil)` and
  # Ollama's own `attach/3`. Every other OpenAI-compatible provider calls
  # `ReqLLM.Keys.get!/2`, which **raises** — so without this list the caller gets
  # an exception from inside a dependency instead of a matchable reason.
  @keyless_providers [:ollama, :lmstudio]

  @known_options ~w[
    model api_key temperature colors count max_tokens detail prompt
    on_invalid_color max_image_bytes receive_timeout
    max_retries total_timeout reqllm_options
  ]a

  # The env layer is a fixed allow-list. `:colors`, `:count`'s per-role form,
  # `:prompt`, and `:reqllm_options` deliberately
  # have no env var: they are structured or code-valued, and a string cannot
  # express them.
  @env_vars %{
    "ACCENTONE_MODEL" => :model,
    "ACCENTONE_API_KEY" => :api_key,
    "ACCENTONE_TEMPERATURE" => :temperature,
    "ACCENTONE_COUNT" => :count,
    "ACCENTONE_MAX_TOKENS" => :max_tokens,
    "ACCENTONE_DETAIL" => :detail,
    "ACCENTONE_ON_INVALID_COLOR" => :on_invalid_color,
    "ACCENTONE_MAX_IMAGE_BYTES" => :max_image_bytes,
    "ACCENTONE_RECEIVE_TIMEOUT" => :receive_timeout,
    "ACCENTONE_MAX_RETRIES" => :max_retries,
    "ACCENTONE_TOTAL_TIMEOUT" => :total_timeout
  }

  # For the shadowed-app-config warning, which names the variable an operator
  # set rather than the option it shadows.
  @env_var_for Map.new(@env_vars, fn {var, name} -> {name, var} end)

  @scalar_defaults %{
    model: "openai:gpt-4o",
    temperature: 0.0,
    colors: [:key, :accent],
    count: 3,
    detail: "low",
    prompt: :default,
    on_invalid_color: :error,
    max_image_bytes: 10_000_000,
    receive_timeout: 60_000,
    max_retries: 1,
    total_timeout: 180_000,
    reqllm_options: []
  }

  defstruct [
    :model,
    :api_key,
    :temperature,
    :colors,
    :counts,
    :max_tokens,
    :detail,
    :prompt,
    :on_invalid_color,
    :max_image_bytes,
    :receive_timeout,
    :max_retries,
    :total_timeout,
    :reqllm_options
  ]

  @typedoc "The fully resolved configuration `analyze/2` consumes."
  @type t :: %__MODULE__{
          model: Model.t(),
          api_key: binary() | nil,
          temperature: number() | nil,
          colors: [Accentone.role()],
          counts: %{Accentone.role() => pos_integer()},
          max_tokens: pos_integer(),
          detail: binary() | nil,
          prompt: :default | :terse | binary(),
          on_invalid_color: :error | :drop,
          max_image_bytes: pos_integer(),
          receive_timeout: pos_integer(),
          max_retries: non_neg_integer(),
          total_timeout: pos_integer() | nil,
          reqllm_options: keyword()
        }

  # -- the README's contract, read from here --------------------------------

  # README.md is the HexDocs front page (`main: "readme"`), so its option table
  # is published surface that happens to live outside `@moduledoc`. These read
  # the private attributes back out so `test/readme_test.exs` can assert the
  # table covers every option, names every env var, quotes every scalar default,
  # and names the keyless providers — one source of truth, checked rather than
  # copied.

  @doc false
  @spec known_options() :: [atom()]
  def known_options, do: @known_options

  @doc false
  @spec env_vars() :: %{binary() => atom()}
  def env_vars, do: @env_vars

  @doc false
  @spec scalar_defaults() :: map()
  def scalar_defaults, do: @scalar_defaults

  @doc false
  @spec keyless_providers() :: [atom()]
  def keyless_providers, do: @keyless_providers

  @doc """
  Resolve `opts` against app config, `ACCENTONE_*`, and the library defaults.

  Returns `{:ok, %Accentone.Config{}}`, or `{:error, reason}` with an
  `{:invalid_option, name, value}` / `:missing_api_key` reason before any I/O.
  """
  @spec resolve(keyword()) :: {:ok, t()} | {:error, Accentone.error_reason()}
  def resolve(opts \\ [])

  def resolve(opts) when is_list(opts), do: do_resolve(opts)
  def resolve(other), do: {:error, {:invalid_option, :opts, other}}

  defp do_resolve(opts) do
    with {:ok, opts_src} <- keyword_source(opts, :opts),
         {:ok, app_src} <- keyword_source(Application.get_all_env(:accentone), :app),
         env_src <- env_source(),
         merged <- merge_sources(opts_src, app_src, env_src),
         {:ok, decoded} <- decode_sources(merged),
         {:ok, resolved} <- validate(decoded) do
      warn_shadowed(opts_src, app_src, env_src)
      warn_plaintext(resolved)
      {:ok, resolved}
    end
  end

  # -- precedence -----------------------------------------------------------

  # No profile expansion and so no special case: a profile used to be a map of
  # supplied values that had to rank at the level that wrote it, which is what
  # made this a function rather than one `Map.merge/2` chain.
  #
  # Each value is tagged with the level that supplied it so `decode_sources/1`
  # can type it *after* the merge. Typing on the way in would let a losing
  # source veto the call — an unparseable `ACCENTONE_TEMPERATURE` or a malformed
  # app-level `:api_key` would fail even when `opts` supplied a good value,
  # which is exactly what "highest first" promises cannot happen.
  #
  # The env layer outranks app config (README "Where an option comes from").
  # `config/config.exs` is evaluated at build time and baked into the release,
  # while `System.get_env/1` is read at boot — so the layer an operator can
  # change without rebuilding wins. This is the reverse of what a 12-factor
  # background expects to *need*, but not of what it expects to *get*: the same
  # override is still available, and `opts` still outranks both, which is what
  # keeps the two costs of this rank (a string `ACCENTONE_MODEL` shadowing a
  # structured app-level model spec, and app config being unable to retract a
  # credential the environment supplies) visible at the call site instead of
  # silent. Both are documented in §4.
  defp merge_sources(opts_src, app_src, env_src) do
    @scalar_defaults
    |> Map.new(fn {name, value} -> {name, {:default, value}} end)
    |> merge_level(app_src, :app)
    |> merge_level(env_src, :env)
    |> merge_level(opts_src, :opts)
  end

  defp merge_level(merged, source, level) do
    Enum.reduce(source, merged, fn {name, value}, acc ->
      Map.put(acc, name, {level, value})
    end)
  end

  # -- one precedence source ------------------------------------------------

  # Turn a keyword list of options into a map of *supplied* options. Only the
  # names are checked here, because a name is a claim about the option surface
  # rather than a value: `:color` for `:colors` is an error even when `opts`
  # supplies every value (README "Where an option comes from"). Values are
  # decoded after the merge, so a lower layer cannot fail a call it loses —
  # including the env layer, which now loses only to `opts`.
  defp keyword_source(pairs, level) do
    with :ok <- validate_names(pairs, level) do
      {:ok, Map.new(pairs)}
    end
  end

  defp validate_names(pairs, level) do
    Enum.find_value(pairs, :ok, fn
      {name, value} ->
        if name in @known_options, do: nil, else: {:error, {:invalid_option, name, value}}

      name when is_atom(name) ->
        if name in @known_options, do: nil, else: {:error, {:invalid_option, name, nil}}

      other ->
        {:error, {:invalid_option, level, other}}
    end)
  end

  # -- typing, after the merge ----------------------------------------------

  # Decode the winning value of every option, in `@known_options` order so which
  # of two malformed winners is reported does not depend on map iteration.
  defp decode_sources(merged) do
    @known_options
    |> Enum.filter(&Map.has_key?(merged, &1))
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
      case decode_tagged(name, Map.fetch!(merged, name)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # `opts` and app config are already Elixir terms; only the env layer is a
  # string that needs parsing, and only the winning layer is parsed at all.
  defp decode_tagged(:api_key, {level, raw}), do: decode_api_key(raw, level)
  defp decode_tagged(name, {:env, raw}), do: parse_env(name, raw)
  defp decode_tagged(_name, {_level, value}), do: {:ok, value}

  # The tri-state tag. `api_key: nil` is a deliberate "send no credential" only
  # when written in `opts`; a literal `nil` from app config is almost always an
  # unset secret, so it resolves to *unset*. `""` never reaches here from the
  # env layer — `env_source/0` drops it as not supplied, which is the one place
  # the env layer spells "unset" differently from app config and `opts`.
  defp decode_api_key(nil, :opts), do: {:ok, :intentional_nil}
  defp decode_api_key(nil, _level), do: {:ok, :unset}

  defp decode_api_key(value, _level) when is_binary(value) and value != "",
    do: {:ok, {:key, value}}

  defp decode_api_key(value, _level), do: {:error, {:invalid_option, :api_key, value}}

  # -- environment ----------------------------------------------------------

  # The environment is read as *raw strings* and typed after the merge, so a
  # higher-ranked source that supplies the same option shadows an unparseable
  # value instead of being ambushed by it. `""` counts as not supplied rather
  # than as an empty string (§4): a source contributes nothing for that name.
  defp env_source do
    Enum.reduce(@env_vars, %{}, fn {var, name}, acc ->
      case System.get_env(var) do
        nil -> acc
        "" -> acc
        raw -> Map.put(acc, name, raw)
      end
    end)
  end

  defp parse_env(:detail, raw),
    do: match_name(:detail, raw, %{"low" => "low", "high" => "high", "auto" => "auto"})

  defp parse_env(:on_invalid_color, raw),
    do: match_name(:on_invalid_color, raw, %{"error" => :error, "drop" => :drop})

  defp parse_env(:model, raw), do: {:ok, raw}
  defp parse_env(:temperature, raw), do: parse_float(:temperature, raw)
  defp parse_env(:count, raw), do: parse_integer(:count, raw)
  defp parse_env(:max_tokens, raw), do: parse_integer(:max_tokens, raw)
  defp parse_env(:max_image_bytes, raw), do: parse_integer(:max_image_bytes, raw)
  defp parse_env(:receive_timeout, raw), do: parse_integer(:receive_timeout, raw)
  defp parse_env(:max_retries, raw), do: parse_integer(:max_retries, raw)
  defp parse_env(:total_timeout, raw), do: parse_integer(:total_timeout, raw)

  defp match_name(name, raw, allowed) do
    case Map.fetch(allowed, raw) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_option, name, raw}}
    end
  end

  defp parse_integer(name, raw) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> {:error, {:invalid_option, name, raw}}
    end
  end

  defp parse_float(name, raw) do
    case Float.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> {:error, {:invalid_option, name, raw}}
    end
  end

  # -- validation -----------------------------------------------------------

  # The model comes first because two later checks read what it resolves to:
  # `:api_key` is validated against the provider, and the plaintext warning needs
  # the endpoint. Neither can be decided from the spec string alone.
  defp validate(m) do
    with {:ok, spec} <- Map.fetch(m, :model),
         {:ok, model} <- Model.resolve(spec),
         {:ok, api_key} <- resolve_api_key(Map.get(m, :api_key, :unset), model.provider),
         {:ok, temperature} <- validate_temperature(Map.get(m, :temperature)),
         {:ok, colors} <- validate_colors(Map.get(m, :colors)),
         {:ok, counts} <- validate_count(Map.get(m, :count), colors),
         {:ok, max_tokens} <- resolve_max_tokens(Map.fetch(m, :max_tokens), counts),
         {:ok, detail} <- validate_detail(Map.get(m, :detail)),
         {:ok, prompt} <- validate_prompt(Map.get(m, :prompt)),
         {:ok, on_invalid_color} <- validate_on_invalid_color(Map.get(m, :on_invalid_color)),
         {:ok, max_image_bytes} <-
           validate_positive_integer(:max_image_bytes, Map.get(m, :max_image_bytes)),
         {:ok, receive_timeout} <-
           validate_positive_integer(:receive_timeout, Map.get(m, :receive_timeout)),
         {:ok, max_retries} <-
           validate_non_negative_integer(:max_retries, Map.get(m, :max_retries)),
         {:ok, total_timeout} <- validate_total_timeout(Map.get(m, :total_timeout)),
         {:ok, reqllm_options} <- validate_reqllm_options(Map.get(m, :reqllm_options)) do
      {:ok,
       %__MODULE__{
         model: model,
         api_key: api_key,
         temperature: temperature,
         colors: colors,
         counts: counts,
         max_tokens: max_tokens,
         detail: detail,
         prompt: prompt,
         on_invalid_color: on_invalid_color,
         max_image_bytes: max_image_bytes,
         receive_timeout: receive_timeout,
         max_retries: max_retries,
         total_timeout: total_timeout,
         reqllm_options: reqllm_options
       }}
    end
  end

  # A keyless provider needs no credential, so an *unset* key is the normal case
  # there rather than a failure: `analyze(path, model: "ollama:llava")` has to work
  # with nothing configured at all, and demanding a key for a server that has none
  # is the kind of error that makes a library look broken.
  #
  # An explicit `nil` is a different claim. It says "send no credential", which
  # only a keyless adapter can honour, so it is rejected everywhere else —
  # otherwise it would be an exception raised from inside `ReqLLM.Keys.get!/2`.
  defp resolve_api_key(:unset, provider) when provider in @keyless_providers, do: {:ok, nil}
  defp resolve_api_key(:unset, _provider), do: {:error, :missing_api_key}
  defp resolve_api_key({:key, value}, _provider), do: {:ok, value}

  defp resolve_api_key(:intentional_nil, provider) do
    if provider in @keyless_providers do
      {:ok, nil}
    else
      {:error, {:invalid_option, :api_key, nil}}
    end
  end

  defp validate_temperature(nil), do: {:ok, nil}
  defp validate_temperature(t) when is_number(t) and t >= 0.0 and t <= 2.0, do: {:ok, t}
  defp validate_temperature(value), do: {:error, {:invalid_option, :temperature, value}}

  defp validate_colors(colors) when is_list(colors) and colors != [] do
    roles = Prompt.roles()

    if Enum.all?(colors, &(&1 in roles)) and Enum.uniq(colors) == colors do
      {:ok, colors}
    else
      {:error, {:invalid_option, :colors, colors}}
    end
  end

  defp validate_colors(value), do: {:error, {:invalid_option, :colors, value}}

  defp validate_count(count, colors) when is_integer(count) do
    if count in 1..10 do
      {:ok, Map.new(colors, &{&1, count})}
    else
      {:error, {:invalid_option, :count, count}}
    end
  end

  defp validate_count(count, colors) when is_list(count) do
    cond do
      count == [] ->
        {:error, {:invalid_option, :count, count}}

      not Keyword.keyword?(count) ->
        {:error, {:invalid_option, :count, count}}

      Keyword.keys(count) != Enum.uniq(Keyword.keys(count)) ->
        {:error, {:invalid_option, :count, count}}

      Enum.any?(count, fn {role, value} ->
        role not in colors or not (is_integer(value) and value in 1..10)
      end) ->
        {:error, {:invalid_option, :count, count}}

      true ->
        # A requested role that is not named defaults to 3.
        {:ok, Map.new(colors, fn role -> {role, Keyword.get(count, role, 3)} end)}
    end
  end

  defp validate_count(value, _colors), do: {:error, {:invalid_option, :count, value}}

  defp resolve_max_tokens(:error, counts) do
    {:ok, max(256, 64 + 24 * Enum.sum(Map.values(counts)))}
  end

  defp resolve_max_tokens({:ok, value}, _counts) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp resolve_max_tokens({:ok, value}, _counts),
    do: {:error, {:invalid_option, :max_tokens, value}}

  defp validate_detail(detail) when detail in [nil, "low", "high", "auto"], do: {:ok, detail}
  defp validate_detail(value), do: {:error, {:invalid_option, :detail, value}}

  defp validate_prompt(prompt) when prompt in [:default, :terse], do: {:ok, prompt}
  defp validate_prompt(prompt) when is_binary(prompt) and prompt != "", do: {:ok, prompt}
  defp validate_prompt(value), do: {:error, {:invalid_option, :prompt, value}}

  # NB: the whole-token role-key check for `:terse`/custom binaries is phase
  # 4's, and runs as a pre-flight step in the pipeline before any I/O.
  defp validate_on_invalid_color(value) when value in [:error, :drop], do: {:ok, value}
  defp validate_on_invalid_color(value), do: {:error, {:invalid_option, :on_invalid_color, value}}

  defp validate_positive_integer(_name, value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_positive_integer(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_non_negative_integer(_name, value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp validate_non_negative_integer(name, value), do: {:error, {:invalid_option, name, value}}

  # `nil` means no deadline, which is what `ReqLLM` calls `:infinity`; a finite
  # value bounds the whole call, retry delays included.
  defp validate_total_timeout(nil), do: {:ok, nil}
  defp validate_total_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_total_timeout(value), do: {:error, {:invalid_option, :total_timeout, value}}

  defp validate_reqllm_options(value) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, value},
      else: {:error, {:invalid_option, :reqllm_options, value}}
  end

  defp validate_reqllm_options(value), do: {:error, {:invalid_option, :reqllm_options, value}}

  # -- the shadowed-app-config warning ---------------------------------------

  # The env layer outranks app config, which is the rank §4 argues for and the
  # caller-facing README states — but it is also the one case where a value the
  # application author wrote is ignored in the direction a reader is least
  # likely to expect, so it is said out loud rather than left to be discovered.
  #
  # Only a value that *won* is reported: when `opts` supplies the option too, the
  # app-config value loses to the call site either way, and the environment is not
  # what shadowed it — so `opts` is part of the test, not just `app_src ∩ env_src`.
  # The names come out in `@known_options` order so which of two shadowed options
  # leads the message does not depend on map iteration.
  #
  # Nothing but the option and the variable names reaches the log: a shadowed
  # `:api_key` is exactly the case where printing either value would be worst.
  # Like the plaintext warning below it fires once per call and the decision stays
  # the caller's — put the option in `opts` to override the environment.
  defp warn_shadowed(opts_src, app_src, env_src) do
    shadowed =
      Enum.filter(@known_options, fn name ->
        Map.has_key?(env_src, name) and Map.has_key?(app_src, name) and
          not Map.has_key?(opts_src, name)
      end)

    if shadowed != [], do: Logger.warning(fn -> shadowed_warning(shadowed) end)
  end

  defp shadowed_warning([name]) do
    "Accentone: #{Map.fetch!(@env_var_for, name)} is set and outranks " <>
      "config :accentone for #{inspect(name)}; the app-config value is ignored — " <>
      "pass the option in the call to override the environment"
  end

  defp shadowed_warning(names) do
    vars = Enum.map_join(names, ", ", &Map.fetch!(@env_var_for, &1))
    options = Enum.map_join(names, ", ", &inspect/1)

    "Accentone: #{vars} are set and outrank config :accentone for #{options}; " <>
      "the app-config values are ignored — pass the options in the call to " <>
      "override the environment"
  end

  # -- the plaintext warning -----------------------------------------------

  # Resolved, but not rejected: a LAN endpoint may genuinely need `http://`. The
  # library refuses to leak silently instead — one warning per call, naming the
  # host, before sending — and the decision stays the caller's.
  #
  # What is warned about is the *payload*, not the credential: the image and the
  # prompt travel in the clear on every request, so a keyless provider is warned
  # about exactly as loudly as a keyed one. Only the wording depends on the key,
  # and it branches on `is_binary(api_key)` — which is precisely "a bearer token
  # is being sent" — so the message never claims a credential that is not on the
  # wire. (Only the two keyless adapters can resolve to a `nil` key; a `nil` for
  # any other provider is a pre-flight error and never reaches here.)
  #
  # The endpoint comes from the *resolved model*, so it covers all three spec
  # shapes and also the case where nothing was supplied and the provider's own
  # default is plaintext. Both local providers default to loopback, which is not
  # a leak, so this only fires for a host the caller actually named.
  defp warn_plaintext(%__MODULE__{model: %Model{base_url: base_url}, api_key: api_key})
       when is_binary(base_url) do
    case URI.parse(base_url) do
      # A schemeless or otherwise non-`http` endpoint never reaches the wire —
      # `Req` rejects it — so there is nothing to leak and nothing to warn
      # about. The empty host of `http:///v1` is the same case.
      %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
        warn_plaintext_host(host, is_binary(api_key))

      _other ->
        :ok
    end
  end

  defp warn_plaintext(_resolved), do: :ok

  defp warn_plaintext_host(host, keyed?) do
    unless loopback?(host) do
      Logger.warning(fn -> plaintext_warning(host, keyed?) end)
    end
  end

  defp plaintext_warning(host, true) do
    "Accentone: sending the image, prompt, and bearer token over plaintext http to " <>
      "#{host}; use https if that traffic must not be readable on the network"
  end

  defp plaintext_warning(host, false) do
    "Accentone: sending the image and prompt over plaintext http to #{host} " <>
      "(no credential is sent); use https if that traffic must not be readable on the network"
  end

  defp loopback?(host) do
    host = String.downcase(host)

    host == "localhost" or host == "::1" or
      match?({:ok, {127, _, _, _}}, :inet.parse_ipv4strict_address(String.to_charlist(host)))
  end
end
