
# Accentone

Extract a **color palette** from an image with an LLM vision model — in the
cloud or on your own machine.

![CI](https://img.shields.io/github/actions/workflow/status/eiger-code/ex-accentone/elixir.yml?branch=main)
![Hex.pm](https://img.shields.io/hexpm/v/accentone)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Elixir: ~> 1.18](https://img.shields.io/badge/Elixir-~%3E%201.18-4B275F)
![Erlang/OTP: 27 | 28 | 29](https://img.shields.io/badge/OTP-27_%7C_28_%7C_29-6E4A7E)

- 🎨 **Two roles, six when you ask**: `:key` and `:accent` by default, plus `:background`, `:surface`, `:muted`, `:highlight`
- 🖼 **Path or bytes**: tag it `{:path, p}` / `{:bytes, b}`, or let the classifier decide
- 🔌 **Cloud or local**: OpenAI, Anthropic, Ollama, LM Studio, or any OpenAI-compatible gateway
- 🪶 **No image dependency**: no libvips, no ImageMagick — resize in your code, pass `{:bytes, b}`
- 🔁 **Bounded**: `:max_tokens` follows your roles, `:total_timeout` caps the call
- ⏳ **Synchronous by design**: there is no async API — run it in a `Task` or an `Oban` job, never on a request path
- 📡 **Observable**: telemetry carries counts and outcomes, never the body; every failure is matchable

**Jump to** [Quickstart](#quickstart) · [Roles](#roles) · [Configuration](#configuration) · [Error handling](#error-handling) · [Telemetry](#telemetry) · [Changelog](CHANGELOG.md)

## Installation

Add `accentone` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:accentone, "~> 0.1.0"}
  ]
end
```

### The API key

`api_key:` resolves through the same layers as every other option — see
[Where an option comes from](#where-an-option-comes-from):

```elixir
Accentone.analyze(path, api_key: "sk-…")

# config/runtime.exs
config :accentone, api_key: System.fetch_env!("ACCENTONE_API_KEY")
```

With nothing set at any layer, the first call is `{:error, :missing_api_key}`
rather than an unauthenticated request. A provider that needs no key is
unaffected: `model: "ollama:llava"` works with nothing configured at all.

`api_key: nil` is not "unset": in the call it asserts *send no credential*, which
only `:ollama` and `:lmstudio` can honour — the two adapters that omit the
`Authorization` header — and anywhere else it is a pre-flight
`{:invalid_option, :api_key, nil}`. A `nil` from app config *is* unset, so
`config :accentone, api_key: System.get_env("X")` resolves to no key of its own
when `X` is empty instead of quietly sending an anonymous request — but "no key
of its own" is not "no key": the environment outranks app config, so an
`ACCENTONE_API_KEY` still supplies one (see
[Where an option comes from](#where-an-option-comes-from)).

Because `ReqLLM` depends on `dotenvy`, a `.env` in the **current working
directory** feeds `ACCENTONE_API_KEY` too — at application start, and never
overriding a real environment variable. It lands in the environment layer, which
outranks app config, so a stray `.env` in whichever directory you happen to
launch from can override `config :accentone` as well.
`config :req_llm, load_dotenv: false` turns that off.

## Usage

### Quickstart

```elixir
{:ok, palette} = Accentone.analyze("photo.jpg")

palette.key_colors
# => [%Accentone.Color{hex: "#3A6EA5", confidence: 0.87}]

Accentone.Palette.get(palette, :accent)
# => [%Accentone.Color{hex: "#FFB000", confidence: 0.72}]
```

`analyze/2` and `analyze!/2` both take one or two arguments; the raising twin
returns the bare palette or raises `Accentone.Error` carrying the same reason:

```elixir
palette = Accentone.analyze!("photo.jpg")
```

### Blocking, and where to call it

`analyze/2` is synchronous, and there is no async API by design. `:total_timeout`
(180 s by default) bounds the whole call — every attempt, every `Retry-After`
wait, and the upload — so a server answering `Retry-After: 3600` costs the
deadline, not an hour of a worker. **Do not await it on a request path**
regardless: 180 s exceeds the typical 30 s proxy or platform idle timeout
(Heroku, most ALBs, Cowboy's defaults). Put it in a `Task`, an `Oban` job, or a
queue; for a batch, `Task.async_stream/3` makes the concurrency limit explicit.

### Roles

Request any of the six built-in roles with `colors:`; each ships its own prompt
description so `:key` and `:accent` (or `:background` and `:surface`) are
disambiguated by the model:

| role | meaning | field |
| --- | --- | --- |
| `:key` | defines the emotional tone, theme, or subject; independent of area | `key_colors` |
| `:accent` | used sparingly, high visual impact; draws attention, creates contrast | `accent_colors` |
| `:background` | the dominant field the subject sits on | `background_colors` |
| `:surface` | the neutral tone the image implies as a material or base | `surface_colors` |
| `:muted` | the desaturated, low-chroma counterpart to the key color | `muted_colors` |
| `:highlight` | the brightest or most luminous meaningful tone | `highlight_colors` |

```elixir
Accentone.analyze(path, colors: [:key, :accent, :muted], count: 3)
Accentone.analyze(path, colors: [:key, :accent], count: [key: 1, accent: 3])
```

`:colors` defaults to `[:key, :accent]` and `:count` to `3`; in the keyword
form a requested role you leave out also gets `3`, and naming a role `colors:`
did not request is an error — `count:` narrows what was asked for, it cannot add
to it. A **requested** role the model found nothing for is `[]`, and a role you
did not ask for is `nil` — "you didn't ask" must not look like "asked and
empty". Each list is ordered most
important first and holds at most that role's `count` entries; exact duplicate
hex values are collapsed within a list. A response that is empty for *every*
requested role is `{:error, {:invalid_response, :no_colors}}`.

Hold on to that `nil`: `Accentone.Palette.get/2` returns `[]` for a role you did
not request, so it is a total accessor rather than the way to tell the two apart.
Read the field, or `Accentone.Palette.roles/1` — the requested roles, in your
`colors:` order — when the difference matters. `get/2` raises `ArgumentError` for
an atom outside the six, because a misspelled role is a bug and must not look
like an empty palette.

A `confidence` is the model's own score in `0.0..1.0`, and it is **advisory**:
an entry whose score the model omitted, or gave as something that is not a
number, carries `nil` instead of failing the call. Position 1 is the primary
answer for its role and positions 2+ are ordered hints, but no position is
guaranteed to carry one, so treat a `nil` as normal and guard the arithmetic.

Not every unreadable entry fails the call. `:on_invalid_color` — `:error` by
default — decides what an entry the parser cannot read costs: `:error` fails the
call with `{:error, {:invalid_color, {field, index}, raw}}` or
`{:error, {:missing_field, …}}`, while `:drop` discards that one entry and
returns the rest of the list, with the count in telemetry's `dropped` and
`dropped_by_field`. `:drop` is entry-level only: a role whose value is not a
list still fails the call with `{:invalid_response, {field, :not_a_list}}`, so
`:drop` cannot turn a broken payload into a quiet `[]`.

## Reference

### Configuration

#### Options

Every option, its environment variable, and its default:

| option | env var | default |
| --- | --- | --- |
| `:model` | `ACCENTONE_MODEL` | `"openai:gpt-4o"` |
| `:api_key` | `ACCENTONE_API_KEY` | unset → `{:error, :missing_api_key}`; not needed by a keyless provider |
| `:temperature` | `ACCENTONE_TEMPERATURE` | `0.0` (`0.0..2.0`); `nil` omits the key |
| `:colors` | — | `[:key, :accent]` |
| `:count` | `ACCENTONE_COUNT` | `3` (`1..10`); integer or per-role keyword list |
| `:max_tokens` | `ACCENTONE_MAX_TOKENS` | derived from `:colors`/`:count`, floor `256` |
| `:detail` | `ACCENTONE_DETAIL` | `"low"` (or `"high"`, `"auto"`); `nil` omits the key |
| `:prompt` | — | `:default` (or `:terse`, or a custom binary) |
| `:on_invalid_color` | `ACCENTONE_ON_INVALID_COLOR` | `:error` (or `:drop`) |
| `:max_image_bytes` | `ACCENTONE_MAX_IMAGE_BYTES` | `10_000_000` |
| `:receive_timeout` | `ACCENTONE_RECEIVE_TIMEOUT` | `60_000` |
| `:max_retries` | `ACCENTONE_MAX_RETRIES` | `1`; `0` disables retry |
| `:total_timeout` | `ACCENTONE_TOTAL_TIMEOUT` | `180_000`; `nil` has no deadline |
| `:reqllm_options` | — | `[]` |

Four of those options have no env var — `:colors`, `:prompt`, `:reqllm_options`,
and `:count`'s per-role form — because a string cannot express them. For those,
app config is the highest layer that can supply a value, and the precedence list
below stops at position 3.

#### Where an option comes from

Every option — `:api_key` included — resolves in this order, highest first:

1. `opts` passed to `analyze/2`
2. `ACCENTONE_*` environment variable
3. `config :accentone, ...` (compile-time or `config/runtime.exs`)
4. Library default

The environment outranks app config because it is the layer an operator can
change without rebuilding the artifact: `config/config.exs` is evaluated at
build time and baked into the release, while an environment variable is read at
boot. The deploy-time override therefore works whether or not the author reached
for `config/runtime.exs`.

That rank has two costs, and both are worth knowing up front. A string cannot
express a structured model spec, so `ACCENTONE_MODEL` **downgrades** an app-level
`model: {:lmstudio, id: …, base_url: …}` to a catalogued `"provider:id"`, and
`ACCENTONE_COUNT=2` replaces a per-role `count: [key: 5]` with the uniform form.
And a `nil` in app config means *unset*, so it cannot retract a credential the
environment supplies.

What keeps those costs bounded is that `opts` is still highest: a call site can
assert a structured model spec, or `api_key: nil` on a keyless provider, over any
ambient variable — and the option-name check below is not shadowed at all.

A shadowed app-config value is reported rather than left silent, because this is
the one rank where code the author wrote is ignored in the direction a reader is
least likely to expect: `Accentone: ACCENTONE_MODEL is set and outranks config
:accentone for :model; …` is logged once per call. It names the variable and the
option and nothing else — a shadowed `:api_key` must not put either value in a
log. Only a value the environment actually beat is reported, so an option that
`opts` supplies is not mentioned: the call site was going to win either way.

The layers are merged first and only the winning value is typed, so a higher
layer shadows a malformed lower one rather than failing on it: `temperature: 0.5`
in `opts` shadows an unparseable `ACCENTONE_TEMPERATURE`, and an `api_key: 123` in
app config is shadowed by `api_key:` at the call site. A malformed value that
actually wins is still `{:invalid_option, name, value}` before any request — which
now includes an unparseable `ACCENTONE_TEMPERATURE` that outranks a good
`:temperature` in app config. One check is not shadowed, by design: an option
*name* outside the table above is an error wherever it is written — `opts` and
`config :accentone` alike — so a typo fails the call even when `opts` supplies
every value. (An unrecognised `ACCENTONE_*` variable is ignored instead; the env
layer is a fixed allow-list.)

#### Model specs

`:model` is a ReqLLM model spec: `"provider:id"` for a catalogued model, or a
map/tuple carrying `base_url` for a server the catalog does not know. The provider
is named where the model is, so there is no separate endpoint or dialect option to
keep in step:

```elixir
Accentone.analyze(path)                                   # "openai:gpt-4o"
Accentone.analyze(path, model: "anthropic:claude-haiku-4-5")
Accentone.analyze(path, model: "ollama:llava")            # no key needed
Accentone.analyze(path,
  model: {:lmstudio, id: "qwen2.5-vl", base_url: "http://gateway.internal/v1"}
)
```

One requirement is easy to overlook, because nothing fails loudly until a call
does: **structured output is the only output path.** Every request carries a JSON
Schema for the requested roles, and where a provider exposes a structured-output
mode the library asks for `json_schema`, so a model or gateway that ignores the
schema does not degrade into a best-effort parse — it answers
`{:error, {:invalid_json, :no_object}}` or
`{:error, {:invalid_response, :no_colors}}`. That is the first thing to check
when a self-hosted endpoint returns no colors: the image and the prompt arrived,
and the model replied in a shape the library cannot read.

One consequence is worth knowing before you pick a model: **for a self-hosted
OpenAI-compatible server that wants no credential, use `:lmstudio`.** It is the
OpenAI wire with optional auth and `json_schema` structured output, and the one
supported way to reach a gateway that has no key of its own.

An `http` endpoint that is not loopback logs one `Accentone:` warning per call,
naming the host. That holds with or without an API key: the image and the prompt
travel in the clear either way, and the message says whether a bearer token is on
the wire. Loopback (`localhost`, `127.0.0.0/8`, `::1`) never warns, so the local
providers are silent at their defaults.

#### `:prompt` and `:reqllm_options`

`:prompt` is `:default`, `:terse`, or a binary of your own. `:terse` is the
default prompt with the key-color rubric and the scoring bands removed. A binary
is used exactly as supplied. Whatever the kind, the resolved prompt is checked
before any request is made: every requested role's field name must appear in it
as a whole, case-sensitive token, so `key_colors` passes while `Key_Colors` and
`not_key_colors` do not. Otherwise the call is
`{:error, {:invalid_option, :prompt, {:missing_role_key, field}}}` — without it,
a prompt that omits a requested role would be indistinguishable from an image
that has no such color, and both answer `[]`. Only a binary can fail it: the two
built-in prompts are generated from your `colors:`, so their field names are
there by construction.

`:reqllm_options` is the escape hatch for anything else — `:req_http_options`
(`:headers`, `:plug`, a proxy), `:receive_timeout`, a different `:max_retries` —
and it is merged last, so it wins over everything above. One thing it cannot do: a
caller's `authorization` header does not replace the library's, because the
provider layer sets that header after these options apply. Use `:api_key` for the
credential and `:reqllm_options` for the rest.

### Error handling

`analyze/2` returns `{:error, reason}` and `analyze!/2` raises `Accentone.Error`
carrying the identical reason. Retries are narrower than the status code
suggests: a `429`, a `529`, and transport errors (`:closed`, `:timeout`,
`:econnrefused`) are retried up to `:max_retries`, while **any other `5xx` —
`500` and `503` included — is not**, and neither is a `Retry-After` that would
push the call past `:total_timeout`. A transient failure that reaches you
therefore means the retries are already spent, so the call is worth repeating
later; every other reason means an input has to change, since repeating it
verbatim fails the same way. `Accentone.Error` has the full taxonomy, each reason
with what to do about it.

### Input detection

An untagged argument that is valid UTF-8, NUL-free, and at most 4096 bytes is
read as a **path**, and the path is read *before* the bytes are sniffed. Several
image signatures are pure ASCII, so a path like `"GIF89a-notes/photo.png"` looks
like image bytes, and sniffing first would base64-encode the *path string* and
ship it as an image; a raw PNG or JPEG is never valid UTF-8, so path-first costs
that protection nothing. If you hold raw bytes, say so:

```elixir
Accentone.analyze({:bytes, File.read!("photo.jpg")})
```

`{:path, p}` and `{:bytes, b}` bypass only the classifier, never the size or
file-type guard. JPEG, PNG, GIF, and WebP are detected; anything else is
`:not_an_image`. HEIC and AVIF — a phone's default photo format — are
*deliberately* not on that list, along with BMP, TIFF, and SVG: the default
provider does not accept them as vision input, so the entry is refused here
rather than paid for and rejected upstream. The extension is never consulted, so
rename a `.heic` to `.png` and it is still `:not_an_image`; convert it, or use a
provider that takes it. `:max_image_bytes` (default 10 MB) rejects oversized
input before it is base64-encoded.

### Resizing an image

Accentone ships no image codec, so resizing is your code's job: shrink the image
before the call and pass the result as bytes, which is sniffed exactly as a file
path would be.

Vision cost scales with pixel dimensions, not bytes, so shrinking an image is
worth doing only once you raise `:detail` above its `"low"` default:

```elixir
# Vix returns a %Vix.Vips.Image{}, so encode it back to bytes.
{:ok, img} = Vix.Vips.Image.new_from_path(path)
bytes = Vix.Vips.Operation.resize!(img, 0.5) |> Vix.Vips.Image.write_to_buffer!("[Q=80]")

Accentone.analyze({:bytes, bytes}, detail: "high")
```

Resizing before the call also sidesteps `:max_image_bytes`, which guards the
input: downsizing first means a 40 MB photo never has to be base64-encoded at
full size.

### Telemetry

```elixir
:telemetry.attach_many(
  "accentone",
  [[:accentone, :analyze, :start], [:accentone, :analyze, :stop]],
  &handle_event/4,
  nil
)
```

Measurements: `:start` carries `system_time` and `monotonic_time`; `:stop` adds
`duration` (native units), `monotonic_time`, `max_tokens`, `input_tokens` /
`output_tokens` / `total_tokens` (normalized from the provider's `usage`, or `nil`
when there was no reply to read), and `dropped`.

Metadata: every event carries the resolved `model`, `colors`, `counts`, and
`detail`; `:stop` adds `outcome` and `dropped_by_field`.

There is no `:attempts` measurement, by design: the retry decision belongs to
`ReqLLM`'s own step, so a call that was retried is still one `:start`/`:stop`
pair and `duration` covers every attempt. Per-attempt timing is
`[:req_llm, :request, :retry]`, whose events share a `request_id` with
`[:req_llm, :request, :stop]`.

No `[:accentone, …]` event ever carries the body, prompt, image, key, or URL, and
pre-flight failures emit nothing at all — the library never logs a body itself.

One caveat about the layer underneath. `ReqLLM` sends through `Req`, which sends
through `Finch`, and **`Finch` emits the whole request** — the base64 image and
the prompt included — on `[:finch, :send, :start]`. That is `Finch`'s event rather
than this library's, and nothing here changes it. The library's own guarantee
holds; but if you attach a `Finch` handler of your own (some APM agents do),
redact `:body` in it when the images are sensitive.

## Development

```bash
mix deps.get                          # install dependencies
mix test                              # run the test suite
mix test --seed 0 --cover             # fixed order, with the coverage floor
mix format                            # format the code
mix compile --warnings-as-errors      # compile without warnings
mix credo --strict                    # static analysis
mix dialyzer                          # type analysis (first run builds a PLT)
mix hex.audit                         # fail on a retired or advisory package
mix deps.unlock --check-unused        # fail on a stale mix.lock entry
mix hex.build                         # build the Hex tarball, without publishing
mix docs --warnings-as-errors         # build HTML docs into doc/
```

Contributions are welcome. CI runs these on the newest toolchain (Elixir 1.20 /
OTP 29) with three stricter flags: `mix format --check-formatted` instead of
`mix format`; `--warnings-as-errors` on `mix compile` and `mix docs`; and
`--check-locked` on `mix deps.get`, so a `mix.exs` dependency without its
lockfile update fails there instead of resolving silently.

A `compat` matrix re-runs `mix compile --warnings-as-errors` and `mix test`
across the supported range — Elixir 1.18 / OTP 27, Elixir 1.19 / OTP 28, and
Elixir 1.20 / OTP 29 — because a version floor is a promise Hex enforces for
everyone who installs the package, and an unverified promise is a guess.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
