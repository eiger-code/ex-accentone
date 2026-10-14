defmodule Accentone do
  @moduledoc """
  Extract a **color palette** from an image with an LLM vision model — in the
  cloud or on your own machine.

  Motto: **flexibility and simplicity** — one entry point plus its raising twin,
  zero mandatory image-processing dependencies, and every assumption overridable
  at call time.
  """

  alias Accentone.Client
  alias Accentone.Config
  alias Accentone.Error
  alias Accentone.Image
  alias Accentone.Palette
  alias Accentone.Parser
  alias Accentone.Prompt

  @typedoc "A path, raw image bytes, or an explicit tag that skips detection."
  @type input :: binary() | {:path, Path.t()} | {:bytes, binary()}

  @typedoc """
  One of the six built-in color roles.

  This is the type behind a palette's `roles` field and the `colors:` option.
  The vocabulary is fixed and ordered `:key`, `:accent`, `:background`,
  `:surface`, `:muted`, `:highlight`; a request names any subset in any order,
  and `Accentone.Palette.roles/1` preserves *that* order rather than this one.
  """
  @type role :: :key | :accent | :background | :surface | :muted | :highlight

  @typedoc """
  Every reason `Accentone.analyze/2` can return and `Accentone.analyze!/2` can
  raise. `Accentone.Error` renders each one; `t:Accentone.Error.t/0` carries
  it unchanged.
  """
  @type error_reason ::
          :not_an_image
          | :missing_api_key
          | {:enoent, Path.t()}
          | {:eacces, Path.t()}
          | {:eisdir, Path.t()}
          | {:file, atom(), Path.t()}
          | {:invalid_option, atom(), term()}
          | {:image_too_large, non_neg_integer()}
          | {:transport, Exception.t()}
          | {:http, status :: non_neg_integer(), truncated_body :: binary()}
          | {:truncated, :length}
          | {:invalid_json, :no_object | :malformed}
          | {:invalid_response, term()}
          | {:invalid_color, {field :: atom(), index :: non_neg_integer()}, raw :: term()}
          | {:missing_field, {field :: atom(), index :: non_neg_integer()},
             field_name :: String.t()}

  @doc """
  Extract a `Accentone.Palette` from `input`.

  `input` is a file path, raw image bytes, or `{:path, p}` / `{:bytes, b}` to
  settle detection explicitly. `opts` is a keyword list of options. Returns
  `{:ok, %Accentone.Palette{}}`, or `{:error, reason}` with one member of the
  `t:Accentone.error_reason/0` taxonomy. No expected condition raises; use
  `analyze!/2` if you would rather it did.
  """
  @spec analyze(input()) :: {:ok, Palette.t()} | {:error, error_reason()}
  @spec analyze(input(), keyword()) :: {:ok, Palette.t()} | {:error, error_reason()}
  def analyze(input, opts \\ []) do
    with {:ok, config} <- Config.resolve(opts),
         {:ok, loaded} <- Image.load(input, config.max_image_bytes),
         {:ok, prompt} <-
           Prompt.build(config.prompt, config.colors, config.counts) do
      request(config, prompt, loaded)
    end
  end

  @doc """
  The raising twin of `analyze/2`.

  Returns the bare `%Accentone.Palette{}` on success and raises
  `Accentone.Error` carrying the *identical* `reason` that `analyze/2` would
  have returned in `{:error, reason}`.
  """
  @spec analyze!(input()) :: Palette.t()
  @spec analyze!(input(), keyword()) :: Palette.t()
  def analyze!(input, opts \\ []) do
    case analyze(input, opts) do
      {:ok, palette} -> palette
      {:error, reason} -> raise Error, reason: reason
    end
  end

  # -- the pipeline ---------------------------------------------------------

  # Everything from `request/3` down is inside the telemetry span: the
  # pre-flight failures above emit nothing, because no request exists yet. The
  # span covers the HTTP call *and* the parse, so its `:stop` can carry
  # `dropped` and `outcome`.
  defp request(config, prompt, %{bytes: bytes, mime: mime}) do
    start = Client.emit_start(config)

    config
    |> Client.call(prompt, bytes, mime)
    |> finish(config, start)
  end

  defp finish({:ok, result}, config, start) do
    case Parser.parse(result, config.colors, config.counts, config.on_invalid_color) do
      {:ok, %{fields: fields} = parsed} ->
        stop(config, start, result, :ok, parsed.dropped, parsed.dropped_by_field)
        {:ok, palette(config.colors, fields)}

      {:error, reason} ->
        stop(config, start, result, :error, 0, %{})
        {:error, reason}
    end
  end

  defp finish({:error, failure}, config, start) do
    stop(config, start, failure, :error, 0, %{})
    {:error, failure.reason}
  end

  defp stop(config, start, info, outcome, dropped, dropped_by_field) do
    Client.emit_stop(config, %{
      start_monotonic: start.monotonic_time,
      usage: info.usage,
      outcome: outcome,
      dropped: dropped,
      dropped_by_field: dropped_by_field
    })
  end

  # Requested roles in the caller's `colors:` order, `nil` for unrequested
  # and `[]` for requested-and-empty. The parser returns exactly one field per
  # requested role, so every unrequested field keeps the struct default.
  defp palette(colors, fields) do
    Enum.reduce(colors, %Palette{roles: colors}, fn role, palette ->
      field = Prompt.field(role)
      Map.put(palette, field, Map.fetch!(fields, field))
    end)
  end
end
