defmodule Accentone.Client do
  @moduledoc false

  # The provider layer: one `ReqLLM.generate_object/4` per call, with
  # `:reqllm_options` merged last so every transport decision stays the caller's,
  # plus the object/content seam the parser reads and the telemetry events.
  #
  # What is *not* here is the reason this file is a third of its former size: the
  # request body, the `max_tokens`/`max_completion_tokens` spelling, the data URI,
  # the retry predicate, and the envelope/`choices` gate. `ReqLLM` owns all of it
  # per provider, which is the point of the migration.
  #
  # Three constraints shape what remains:
  #
  #   * **The image goes in as bytes plus a sniffed MIME**, and `ReqLLM` builds
  #     the data URI. The sniff stays because it is a `:not_an_image` guard, not a
  #     wire concern.
  #   * **The structured-output knob is derived, not tabulated.** `ReqLLM` reads
  #     it *flat* and silently ignores it nested inside `:provider_options`, and
  #     hard-fails if the key reaches a provider that does not declare it. So it
  #     is asked of the provider module, which is the only source that cannot go
  #     stale.
  #   * **`RepoLLM` errors are mapped, not leaked.** The mapping keeps
  #     `t:Accentone.error_reason/0` exactly as it was — no member added, none
  #     removed — because the README's error table and
  #     `test/readme_test.exs`'s taxonomy check both read it.

  alias Accentone.Config
  alias Accentone.Model
  alias Accentone.Schema
  alias ReqLLM.Message.ContentPart

  # Head-truncation of a non-2xx body, keeping the actionable first bytes.
  @body_limit 2048

  # `:detail` is `"low" | "high" | "auto"` at the API and an atom in the content
  # part. Spelled out rather than `String.to_existing_atom/1`, which would depend
  # on some other module having interned the atom first.
  @detail_atoms %{"low" => :low, "high" => :high, "auto" => :auto}

  @typedoc """
  The provider's normalized `usage` map, or `nil` when there was no reply at all.

  A reply that carries no `usage` normalizes to zero counts with
  `usage_reported` false rather than to `nil`; `nil` means a failure, where no
  reply exists to report from.
  """
  @type usage :: map() | nil

  @typedoc """
  A usable reply, ready for `Accentone.Parser.parse/4`.

  `object` is what `ReqLLM` recovered from the structured reply and `content` is
  its text; the parser prefers the first and falls back to the second.
  """
  @type result :: %{
          object: map() | nil,
          content: binary() | nil,
          finish_reason: atom() | nil,
          usage: usage()
        }

  @typedoc "An error reason plus the `usage` the `:stop` event reports."
  @type failure :: %{reason: Accentone.error_reason(), usage: usage()}

  @doc """
  Send one request for `prompt` + `bytes` and return the parsed-envelope inputs.

  `mime` is the *sniffed* MIME, so the data URI a provider sees never depends on
  a file extension. Success returns the recovered `object`, the reply's
  `content`, its `finish_reason`, and its normalized `usage`; the parser owns
  every content-level decision from there.

  Failure returns `{:error, %{reason: reason, usage: usage}}`. The wrapper —
  rather than a bare `{:error, reason}` — exists because `:stop` telemetry
  reports `usage` on **every** post-request failure, and
  `ReqLLM.generate_object/4` returns only a response or an error.
  """
  @spec call(Config.t(), binary(), binary(), binary()) :: {:ok, result()} | {:error, failure()}
  def call(%Config{} = config, prompt, bytes, mime)
      when is_binary(prompt) and is_binary(bytes) and is_binary(mime) do
    context =
      ReqLLM.Context.user([
        ContentPart.text(prompt),
        ContentPart.image(bytes, mime, detail_metadata(config.detail))
      ])

    options = base_options(config) ++ config.reqllm_options

    case generate(config, context, options) do
      {:ok, %ReqLLM.Response{} = response} ->
        response_result(response)

      {:error, error} ->
        {:error, %{reason: reqllm_reason(error), usage: nil}}
    end
  end

  # `ReqLLM` does not always *return* a malformed reply. Its OpenAI-format decoder
  # has no clause for a `2xx` body that is not a map, so a server answering with a
  # bare list or string makes it fail a function clause — and because a finite
  # `:total_timeout` runs the request in `ReqLLM`'s own task, that arrives here as
  # an exit carrying the exception rather than as a raise. Both are caught so they
  # reach the mapper: `analyze/2`'s contract is that no expected condition raises,
  # and a gateway answering `200` with something that is not an object is an
  # expected condition.
  defp generate(config, context, options) do
    ReqLLM.generate_object(config.model.spec, context, schema(config), options)
  rescue
    error -> {:error, error}
  catch
    :exit, {reason, _stacktrace} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  # -- request options -----------------------------------------------------

  # `nil` entries are dropped rather than sent: a provider must never see `null`
  # where it expects a number, and `:total_timeout`'s "no deadline" is expressed
  # by its absence.
  #
  # One consequence worth knowing: dropping `:api_key` when it is `nil` means a
  # keyless request is keyless *here*, not necessarily end to end — a key already
  # in the environment for that provider's adapter is still `ReqLLM`'s to use.
  defp base_options(%Config{} = config) do
    [
      api_key: config.api_key,
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      receive_timeout: config.receive_timeout,
      max_retries: config.max_retries,
      total_timeout: config.total_timeout
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Kernel.++(output_mode(config.model.module))
  end

  # Some providers declare a structured-output mode knob and some do not: OpenAI
  # and Anthropic declare one, while LM Studio and Ollama force `json_schema`
  # internally and vLLM declares none. `ReqLLM` reads the knob flat and would
  # reject it on the providers that lack it, so the key is discovered from the
  # provider module instead of being listed here — a list would go stale, and
  # being wrong in the "send it anyway" direction fails the call outright.
  defp output_mode(module) do
    module.supported_provider_options()
    |> Enum.find(&String.ends_with?(Atom.to_string(&1), "_structured_output_mode"))
    |> case do
      nil -> []
      key -> [{key, :json_schema}]
    end
  end

  defp detail_metadata(nil), do: %{}
  defp detail_metadata(value), do: %{detail: Map.fetch!(@detail_atoms, value)}

  defp schema(%Config{} = config), do: Schema.build(config.colors, config.counts)

  # -- the reply -----------------------------------------------------------

  defp response_result(%ReqLLM.Response{} = response) do
    content = ReqLLM.Response.text(response)
    usage = response.usage

    {:ok,
     %{
       object: response.object,
       content: content,
       finish_reason: response.finish_reason,
       usage: usage
     }}
  end

  # -- error mapping -------------------------------------------------------

  # The order of these clauses is the mapping, not an accident. An `API.Request`
  # carrying a status is an HTTP failure; one carrying an exception `:cause` is a
  # transport failure even if a status came along; one carrying neither is still a
  # request failure, and `API.Request` is itself an exception, so it renders.
  defp reqllm_reason(%ReqLLM.Error.API.Request{status: status, response_body: body})
       when not is_nil(status) do
    {:http, status, truncate_body(body)}
  end

  defp reqllm_reason(%ReqLLM.Error.API.Request{cause: %{__exception__: true} = cause}),
    do: {:transport, cause}

  defp reqllm_reason(%ReqLLM.Error.API.Request{} = error), do: {:transport, error}
  defp reqllm_reason(%ReqLLM.Error.API.Timeout{} = error), do: {:transport, error}

  # An option a provider does not declare arrives as `Unknown.Unknown` wrapping a
  # `NimbleOptions.ValidationError`, and reporting a caller's typo as a
  # response-shape problem would send them to debug the network for a request that
  # never left. This is defensive rather than load-bearing — the derived knob is
  # what keeps it unreachable on the normal path.
  defp reqllm_reason(%ReqLLM.Error.Unknown.Unknown{
         error: %NimbleOptions.ValidationError{key: [key | _rest]} = inner
       })
       when is_atom(key) do
    {:invalid_option, key, inner.value}
  end

  # Everything else — including a decoder crash caught in `generate/3` — is a
  # reply the library could not read, which is the same call the previous client
  # made in `exception_reason/1`'s catch-all: `Req`'s own body decoder rejecting an
  # envelope was `:not_an_object` then, and `ReqLLM`'s is `:not_an_object` now.
  defp reqllm_reason(_other), do: {:invalid_response, :not_an_object}

  # Head-truncation: keep the first 2048 bytes and mark the cut. The error
  # taxonomy promises a binary here, so anything else is rendered to one.
  #
  # A byte cut can land inside a UTF-8 codepoint, which would put an invalid
  # binary into the `{:http, status, body}` reason and break any host that
  # JSON-encodes it for a structured log. `Accentone.Error` renders the reason
  # through `inspect/1`, so the library is safe either way; when the body is valid
  # UTF-8 the cut is still backed up off the partial codepoint.
  defp truncate_body(body) when is_binary(body) do
    if byte_size(body) > @body_limit do
      prefix = utf8_prefix(binary_part(body, 0, @body_limit), String.valid?(body))
      prefix <> "..."
    else
      body
    end
  end

  defp truncate_body(body) do
    case Jason.encode(body) do
      {:ok, json} -> truncate_body(json)
      {:error, _reason} -> truncate_body(inspect(body))
    end
  end

  # A valid UTF-8 body whose byte cut split a codepoint needs at most three bytes
  # off, and re-checking `String.valid?/1` per byte is the whole rule. A body that
  # was not valid UTF-8 to begin with is left exactly as the server wrote it:
  # there is no prefix of it that would be valid.
  defp utf8_prefix(prefix, true) do
    if String.valid?(prefix) do
      prefix
    else
      utf8_prefix(binary_part(prefix, 0, byte_size(prefix) - 1), true)
    end
  end

  defp utf8_prefix(prefix, false), do: prefix

  # -- telemetry -----------------------------------------------------------

  # The events are emitted from the `analyze/2` pipeline rather than from here,
  # because the span must cover the HTTP call **and** the parse (`:stop` carries
  # `dropped` and `outcome`), while pre-flight failures must emit nothing. These
  # helpers live here because the events belong to this file; the pipeline
  # owns the call sites.

  @doc """
  Emit `[:accentone, :analyze, :start]` and return its measurements.

  The pipeline keeps the returned `:monotonic_time` and hands it back to
  `emit_stop/2` as `:start_monotonic`.
  """
  @spec emit_start(Config.t()) :: %{system_time: integer(), monotonic_time: integer()}
  def emit_start(%Config{} = config) do
    measurements = %{system_time: System.system_time(), monotonic_time: System.monotonic_time()}
    :telemetry.execute([:accentone, :analyze, :start], measurements, metadata(config))
    measurements
  end

  @doc """
  Emit `[:accentone, :analyze, :stop]`.

  `info` carries `:start_monotonic`, `:outcome`, and — post-parse — `:usage`,
  `:dropped`, and `:dropped_by_field`. `duration` is in **native** time units, and
  token counts are `nil` only when there was no reply to report from; a reply that
  reported no `usage` counts zero.

  There is no `:attempts` measurement: the retry decision belongs to `ReqLLM`'s
  own step now. A caller who needs per-attempt timing attaches to
  `[:req_llm, :request, :retry]`, whose events share a `request_id` with
  `[:req_llm, :request, :stop]`.
  """
  @spec emit_stop(Config.t(), map()) :: :ok
  def emit_stop(%Config{} = config, info) do
    now = System.monotonic_time()

    measurements = %{
      duration: now - info.start_monotonic,
      monotonic_time: now,
      max_tokens: config.max_tokens,
      input_tokens: usage_get(info.usage, :input_tokens),
      output_tokens: usage_get(info.usage, :output_tokens),
      total_tokens: usage_get(info.usage, :total_tokens),
      dropped: Map.get(info, :dropped, 0)
    }

    metadata =
      config
      |> metadata()
      |> Map.put(:outcome, info.outcome)
      |> Map.put(:dropped_by_field, Map.get(info, :dropped_by_field, %{}))

    :telemetry.execute([:accentone, :analyze, :stop], measurements, metadata)
  end

  # Counts and resolved options only — never the body, prompt, key, or endpoint
  # (an endpoint can carry a credential in a query parameter, so even the "safe"
  # part is not reliably safe; `Model.label/1` is what keeps it out).
  defp metadata(%Config{} = config) do
    %{
      model: Model.label(config.model),
      colors: config.colors,
      counts: config.counts,
      detail: config.detail
    }
  end

  defp usage_get(usage, key) when is_map(usage), do: Map.get(usage, key)
  defp usage_get(_usage, _key), do: nil
end
