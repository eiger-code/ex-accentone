# Changelog

All notable user-visible changes are recorded here, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The library is pre-1.0, so a minor release may contain a breaking change. This
file is the *what* a caller sees — the *why* behind it, the decisions, the
reviews, and the work deliberately left out, is not recorded here.

## 0.1.0 - 2026-10-14

First release.

### Added

- `Accentone.analyze/2` and its raising twin `Accentone.analyze!/2`: a file path,
  raw bytes, or an explicit `{:path, p}` / `{:bytes, b}` tag in, a
  `%Accentone.Palette{}` out.
- Six color roles — `:key`, `:accent`, `:background`, `:surface`, `:muted`,
  `:highlight` — any subset via `colors:`, each bounded by `count:`, each with its
  own prompt description so the overlapping pairs stay distinguishable.
- Provider-agnostic model specs (`"openai:gpt-4o"`,
  `"anthropic:claude-haiku-4-5"`, `"ollama:llava"`, or
  `{:lmstudio, id: …, base_url: …}`), so a cloud provider and a self-hosted
  gateway are the same option rather than two dialects.
- Keyless providers work with nothing configured at all; `api_key: nil` is a
  validated capability rather than an assumption.
- No image-processing dependency: the format is sniffed from magic bytes (JPEG,
  PNG, GIF, WebP), and resizing stays the caller's, so an oversized image is a
  caller decision rather than a codec in the tree.
- An overridable prompt (`:default`, `:terse`, or a binary of your own) and the
  levers that bound a call: `:detail`, `:temperature`, `:max_tokens`,
  `:max_image_bytes`, `:receive_timeout`, `:max_retries`, `:total_timeout`, and
  `:reqllm_options`.
- `:on_invalid_color` decides what one unreadable entry costs: `:error` (the
  default) fails the call, while `:drop` discards that entry and returns the rest
  of the list, with the count in telemetry's `dropped` and `dropped_by_field`.
  `:drop` is entry-level only — a role whose value is not a list still fails the
  call.
- Configuration resolves `opts` → `ACCENTONE_*` → app config → library default,
  and every option is validated before any I/O, so a typo is a cheap error rather
  than a paid call.
- The environment outranks app config, so a deploy-time `ACCENTONE_*` override
  does not require `config/runtime.exs`. Two consequences, both deliberate: a
  string `ACCENTONE_MODEL` downgrades a structured app-level
  `model: {:lmstudio, id: …, base_url: …}` to a catalogued `"provider:id"`, and
  `ACCENTONE_COUNT` replaces a per-role `count:` with the uniform form — although
  the four options with no env var (`:colors`, `:prompt`, `:reqllm_options`, and
  per-role `:count`) are still app config's to win. An app-level `api_key: nil`
  means *unset* rather than *send no credential*, so it cannot retract a
  credential supplied by `ACCENTONE_API_KEY`; `api_key: nil` at the call site is
  how you assert *send no credential*. A variable that wins over an app-config
  sibling logs one warning naming the variable and the option — never either
  value — so the precedence is visible in the log rather than only in the docs.
- One closed error taxonomy, rendered per member by `Accentone.Error`;
  `analyze!/2` raises it carrying the identical reason `analyze/2` returned.
- `[:accentone, :analyze, :start]` and `:stop` telemetry carrying counts and
  outcomes only — never the image, prompt, body, key, or endpoint.
- `Accentone.Palette.get/2` for `nil`-free iteration, `Accentone.Palette.roles/1`
  for the request order, and `Accentone.Color.valid?/1` for hand-built fixtures.

### Security

- A non-loopback `http` endpoint logs one warning per call naming the host, with
  or without a credential — the image and prompt travel in the clear either way.
- The library itself never logs or telemetries the request body. Note that
  `Finch`, underneath `ReqLLM`, emits the whole request on
  `[:finch, :send, :start]`; redact `:body` in any handler you attach there.
