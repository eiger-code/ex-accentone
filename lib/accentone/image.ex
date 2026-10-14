defmodule Accentone.Image do
  @moduledoc false

  # Input detection in one module: path reading, magic-byte sniffing, MIME, and
  # the size guard.
  #
  # The classifier is **path-first**, and that ordering is the fix for the
  # collision class this ordering prevents rather than an optimisation. Several signatures
  # are pure ASCII, so `"GIF89a-notes/photo.png"` and a `"RIFF....WEBP/…"`
  # relative path both look like image bytes; sniffing first would base64-encode
  # the path string and ship it as an image. A valid-UTF-8, NUL-free argument of
  # at most 4096 bytes is a *candidate path*, and a raw PNG or JPEG is never
  # valid UTF-8 (it opens with `0x89` / `0xFF`), so path-first neither misreads a
  # path as an image nor rejects the two formats that matter. `{:path, _}` and
  # `{:bytes, _}` settle the question by fiat; they bypass only the classifier,
  # never the stat type gate or the size guard.
  #
  # No format outside the four-row signature table is sniffed, and none is
  # guessed at: BMP (two ambiguous ASCII bytes), TIFF, AVIF/HEIC, and SVG are
  # excluded because the default provider does not accept them as vision input,
  # so a request with them would be paid for and rejected anyway. Animated
  # GIF is likewise not detected — `GIF8` covers `GIF87a` and `GIF89a` alike —
  # and the provider's `4xx` body is where the caller learns why.

  # A path longer than this cannot exist, so it is rejected as a path rather
  # than falling through to sniffing. Measured in **bytes**.
  @max_path_bytes 4096

  @jpeg <<0xFF, 0xD8, 0xFF>>
  @png <<0x89, "PNG\r\n", 0x1A, 0x0A>>

  @typedoc "Sniffed bytes plus the MIME the data URI must carry."
  @type image :: %{bytes: binary(), mime: binary()}

  @doc """
  Resolve `input` to `{:ok, %{bytes: bytes, mime: mime}}`.

  `input` is a path, raw bytes, or one of the two tagged tuples; a value of any
  other shape is `{:error, {:invalid_option, :input, value}}` rather than a
  `FunctionClauseError` escaping the library. The size guard is `max_bytes`.
  """
  @spec load(binary() | {:path, Path.t()} | {:bytes, binary()}, pos_integer()) ::
          {:ok, image()} | {:error, Accentone.error_reason()}
  def load(input, max_bytes)

  def load({:path, path}, max_bytes) when is_binary(path), do: load_path(path, max_bytes)

  def load({:bytes, bytes}, max_bytes) when is_binary(bytes),
    do: guarded_sniff(bytes, max_bytes)

  def load(path, max_bytes) when is_binary(path) do
    case classify(path) do
      {:path, candidate} -> load_path(candidate, max_bytes)
      {:bytes, bytes} -> guarded_sniff(bytes, max_bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  def load(input, _max_bytes), do: {:error, {:invalid_option, :input, input}}

  @doc """
  The MIME for `bytes`, or `:error` when no known signature matches.

  The table is the four formats the default provider accepts: JPEG `FF D8 FF`,
  PNG `89 50 4E 47 0D 0A 1A 0A`, GIF `GIF8`, and WebP `RIFF` … `WEBP` at offset
  8. The extension is never consulted, which is why a `photo.jpg` that is really
  a PNG still works.
  """
  @spec sniff(binary()) :: {:ok, binary()} | :error
  def sniff(<<@jpeg, _::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<@png, _::binary>>), do: {:ok, "image/png"}
  def sniff(<<"GIF8", _::binary>>), do: {:ok, "image/gif"}
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def sniff(_other), do: :error

  # -- classifier -----------------------------------------------------------

  # The untagged rule, in order: a valid-UTF-8, NUL-free argument is a path
  # candidate up to 4096 bytes; past that it is a path that cannot exist.
  # Anything else (raw PNG/JPEG bytes, a NUL-bearing blob) goes to the sniff.
  defp classify(binary) do
    if String.valid?(binary) and not nul?(binary) do
      if byte_size(binary) > @max_path_bytes do
        {:error, {:file, :enametoolong, binary}}
      else
        {:path, binary}
      end
    else
      {:bytes, binary}
    end
  end

  defp nul?(binary), do: :binary.match(binary, <<0>>) != :nomatch

  # -- path branch ----------------------------------------------------------

  # The stat type gate and the size guard both run **before** `File.read/1`, so
  # `/dev/zero` cannot be read forever and a FIFO cannot block the caller. The
  # non-regular case synthesizes `:einval` because `File.stat/1` *succeeds* for a
  # device or FIFO (there is no POSIX reason to forward), and an over-long path
  # is rejected here rather than surfacing as a confusing `:not_an_image`.
  defp load_path(path, max_bytes) do
    with :ok <- enforce_path_length(path) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> read_regular(path, size, max_bytes)
        {:ok, %File.Stat{type: :directory}} -> {:error, {:eisdir, path}}
        {:ok, %File.Stat{}} -> {:error, {:file, :einval, path}}
        {:error, :enoent} -> {:error, {:enoent, path}}
        {:error, :eacces} -> {:error, {:eacces, path}}
        {:error, reason} -> {:error, {:file, reason, path}}
      end
    end
  end

  defp enforce_path_length(path) do
    if byte_size(path) > @max_path_bytes,
      do: {:error, {:file, :enametoolong, path}},
      else: :ok
  end

  defp read_regular(path, size, max_bytes) do
    if size > max_bytes do
      # Rejected from the stat *size*, so a multi-gigabyte file is never pulled
      # into memory only to be rejected.
      {:error, {:image_too_large, size}}
    else
      read_file(path)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> to_image(bytes)
      {:error, :enoent} -> {:error, {:enoent, path}}
      {:error, :eacces} -> {:error, {:eacces, path}}
      {:error, reason} -> {:error, {:file, reason, path}}
    end
  end

  # -- byte branch ----------------------------------------------------------

  defp guarded_sniff(bytes, max_bytes) do
    if byte_size(bytes) > max_bytes do
      {:error, {:image_too_large, byte_size(bytes)}}
    else
      to_image(bytes)
    end
  end

  defp to_image(bytes) do
    case sniff(bytes) do
      {:ok, mime} -> {:ok, %{bytes: bytes, mime: mime}}
      :error -> {:error, :not_an_image}
    end
  end
end
