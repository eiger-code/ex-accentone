defmodule Accentone.Error do
  @moduledoc """
  The exception `Accentone.analyze!/2` raises.

  It is an ordinary exception struct, which is what keeps the raise matchable
  instead of opaque. The `reason` field is the contract — it is *identical* to
  the tuple `Accentone.analyze/2` would have returned — and the message is for
  humans and is allowed to change:

      %Accentone.Error{reason: {:http, 429, "slow down"}}

      iex> raise Accentone.Error, reason: {:invalid_response, :no_colors}
      ** (Accentone.Error) model returned no colors for any requested role

  `t:Accentone.error_reason/0` enumerates every value `reason` can take; `message/1`
  has a clause for each of them.

  ## The reasons, and what to do

  Every member of the taxonomy, with the fix for each. `Accentone.analyze/2`
  returns one as `{:error, reason}`; `Accentone.analyze!/2` raises it unchanged.

  | reason | what to do |
  | --- | --- |
  | `:not_an_image` | Not JPEG/PNG/GIF/WebP. Fix the path, or pass `{:bytes, b}`. |
  | `:missing_api_key` | Set `:api_key`, `config :accentone, :api_key`, or `ACCENTONE_API_KEY` — unless the model spec names a keyless provider, which needs none. |
  | `{:enoent, path}` / `{:eacces, path}` / `{:eisdir, path}` / `{:file, reason, path}` | The path could not be read. Fix the path or permissions. |
  | `{:invalid_option, name, value}` | A typo, an out-of-range value, `api_key: nil` for a provider that cannot honour it, or a custom `:prompt` that omits a requested role. No request was made. |
  | `{:image_too_large, bytes}` | Raise `:max_image_bytes`, or shrink the image first. |
  | `{:transport, exception}` | The request never completed (DNS, connection, timeout). |
  | `{:http, status, body}` | The endpoint answered non-2xx; `body` is head-truncated to 2048 bytes. |
  | `{:truncated, :length}` | The model hit the token cap. Raise `:max_tokens` or request fewer roles. |
  | `{:invalid_json, :no_object}` / `{:invalid_json, :malformed}` | The answer was not a JSON object. Retry, or switch model/prompt. |
  | `{:invalid_response, term}` | The envelope or a role's value had the wrong shape. `term` is one of the seven shapes listed below. |
  | `{:invalid_color, {field, index}, raw}` | A malformed entry. Use `on_invalid_color: :drop` to keep the rest. |
  | `{:missing_field, {field, index}, field_name}` | Same, for a missing `hex`, which is the only required key of an entry. A missing or unreadable `confidence` is `nil` instead — never this error. |

  ## `:invalid_response` shapes

  `term` is one of the seven:

  - `:not_an_object`, `:no_colors`
  - `{:choices, :empty}`, `{:content, :null}`, `{:content, :not_a_string}`
  - `{field, :not_a_list}`, `{field, index, :not_an_object}`

  `{:choices, :empty}` is the one member the provider layer no longer produces: a
  reply with no usable choice is an empty reply, which the parser then rejects as
  `{:invalid_json, :no_object}`. It stays in the taxonomy because it is still a
  shape a reply can have.

  ## Retries

  Transient failures — `429`, `529`, and transport errors (`:closed`, `:timeout`,
  `:econnrefused`) — are retried up to `:max_retries`. Three things decline a retry
  rather than performing it: `:max_retries` of `0`; any other 5xx, including `500`
  and `503`, which is **not** retried; and a `Retry-After` that would push the call
  past `:total_timeout`, which returns `{:transport, %ReqLLM.Error.API.Timeout{}}`.
  A transient failure that reaches you therefore means the retries are spent — the
  call is unchanged, so it is worth repeating later — while every other reason
  means an input has to change, since repeating it verbatim would fail the same way.

  Retry counts are `ReqLLM`'s, not this library's, so `[:accentone, :analyze, :stop]`
  carries no `attempts`. Attach to `[:req_llm, :request, :retry]` for per-attempt
  timing; its events share a `request_id` with `[:req_llm, :request, :stop]`.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: Accentone.error_reason()}

  # HTTP body cap: head-truncated to 2048 bytes, ellipsis only when
  # truncation occurred. The client truncates before building the tuple;
  # rendering it here is idempotent with that rule, so a message built from
  # either the raw or the pre-truncated body reads the same way.
  @body_limit 2048

  @impl true
  def message(%__MODULE__{reason: reason}), do: message(reason)

  @doc """
  A human-readable rendering of one member of the error-reason taxonomy — or of
  an `Accentone.Error` itself, so the `Exception` callback is covered.

  Every member has its own clause; there is no `inspect(reason)` fallback.
  """
  @spec message(t() | Accentone.error_reason()) :: String.t()
  def message(:not_an_image),
    do: "input is not a supported image (JPEG, PNG, GIF, and WebP are supported)"

  def message(:missing_api_key) do
    "no API key configured (pass :api_key, set `config :accentone, api_key: ...`, " <>
      "or set ACCENTONE_API_KEY)"
  end

  def message({:enoent, path}), do: "file not found: #{path}"
  def message({:eacces, path}), do: "permission denied reading file: #{path}"
  def message({:eisdir, path}), do: "expected a file but found a directory: #{path}"
  def message({:file, reason, path}), do: "could not read file #{path}: #{reason}"

  # `api_key: nil` is not a typo, it is a capability, so the generic rendering
  # below would hide the fix. Only the adapters that suppress the
  # `authorization` header can send no credential, and the useful answer names
  # the provider that can rather than repeating the reason back. This clause has
  # to come first: `{:invalid_option, term(), term()}` matches it too.
  def message({:invalid_option, :api_key, nil}) do
    "`api_key: nil` sends no credential, which only `:ollama` and `:lmstudio` " <>
      "support. For another OpenAI-compatible server, use a `:lmstudio` model spec " <>
      "carrying its own `base_url`: it has optional auth and speaks the OpenAI wire"
  end

  def message({:invalid_option, name, value}),
    do: "invalid option #{inspect(name)}: #{inspect(value)}"

  def message({:image_too_large, size}), do: "image is too large (#{size} bytes)"

  def message({:transport, exception}),
    do: "transport error: #{Exception.message(exception)}"

  def message({:http, status, body}),
    do: "request failed with status #{status}: #{render_body(body)}"

  def message({:truncated, :length}) do
    "model response was truncated (finish_reason \"length\"); " <>
      "increase max_tokens or request fewer roles"
  end

  def message({:invalid_json, :no_object}), do: "model response contained no JSON object"
  def message({:invalid_json, :malformed}), do: "model response contained malformed JSON"

  def message({:invalid_response, :no_colors}),
    do: "model returned no colors for any requested role"

  def message({:invalid_response, :not_an_object}), do: "model response was not a JSON object"

  def message({:invalid_response, {:choices, :empty}}),
    do: "model response contained no usable choices"

  def message({:invalid_response, {:content, :null}}),
    do: "model response contained no content"

  def message({:invalid_response, {:content, :not_a_string}}),
    do: "model content was not a string"

  def message({:invalid_response, {field, :not_a_list}}),
    do: "expected a list of colors for #{field}, got a non-list value"

  def message({:invalid_response, {field, index, :not_an_object}}),
    do: "expected an object for #{field} entry #{index}, got a non-object"

  def message({:invalid_response, other}),
    do: "unexpected model response: #{inspect(other)}"

  def message({:invalid_color, {field, index}, raw}),
    do: "invalid color at #{field}[#{index}]: #{inspect(raw)}"

  def message({:missing_field, {field, index}, field_name}),
    do: "missing #{inspect(field_name)} at #{field}[#{index}]"

  defp render_body(body) when is_binary(body) and byte_size(body) > @body_limit do
    inspect(binary_part(body, 0, @body_limit) <> "...")
  end

  defp render_body(body), do: inspect(body)
end
