defmodule Accentone.Fixtures do
  @moduledoc false

  # The signature table as hardcoded byte strings — no binary assets in the
  # repo. Each of the four is a real, structurally valid 1×1 image; `file(1)`
  # identifies all of them.
  #
  #   $ file fx_png fx_jpeg fx_gif fx_webp
  #   fx_png:  PNG image data, 1 x 1, 8-bit/color RGBA, non-interlaced
  #   fx_jpeg: JPEG image data, JFIF standard 1.01, baseline, 1x1, components 1
  #   fx_gif:  GIF image data, version 89a, 1 x 1
  #   fx_webp: RIFF (little-endian) data, Web/P image, VP8 encoding, 1x1

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
       )
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="
        )
  @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
  @webp Base.decode64!("UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=")

  @doc "1×1 PNG — `89 50 4E 47 0D 0A 1A 0A` → `image/png`."
  def png, do: @png

  @doc "1×1 JPEG — `FF D8 FF` → `image/jpeg`."
  def jpeg, do: @jpeg

  @doc "1×1 `GIF89a` — `47 49 46 38` (`GIF8`) → `image/gif`."
  def gif, do: @gif

  @doc "1×1 WebP — `52 49 46 46` (`RIFF`) … `57 45 42 50` (`WEBP`) at offset 8."
  def webp, do: @webp

  @doc """
  A valid-UTF-8, NUL-free candidate path longer than the 4096-byte limit:
  4097 ASCII bytes.

  It is rejected as `{:file, :enametoolong, path}` rather than falling through
  to signature sniffing — without that rule an over-long path would surface as a
  confusing `:not_an_image`.
  """
  def over_long_path, do: String.duplicate("a", 4097)

  @doc """
  The same rule, measured in **bytes**: 2049 × `"é"` is 4098 bytes but only 2049
  characters.

  An implementation that gated on `String.length/1` would wrongly read it as a
  path, so this fixture pins the "at most 4096 **bytes**" rule.
  """
  def over_long_multibyte_path, do: String.duplicate("é", 2049)

  @doc """
  Valid UTF-8 that contains a NUL byte.

  The classifier requires NUL-free, so this is never a path: it falls through to
  the sniff and matches no signature.
  """
  def nul_path, do: <<"a", 0, "b">>

  @doc """
  A relative path whose *bytes* match `GIF8`.

  Read as a file, never sniffed as an image: this is the collision class that
  path-first detection exists to remove.
  """
  def gif_shaped_path, do: "GIF89a-notes/photo.png"

  @doc """
  A relative path whose bytes match `RIFF` … `WEBP` at offset 8 — the other
  ASCII-signature collision.
  """
  def webp_shaped_path, do: "RIFF....WEBP/photo.png"

  @doc """
  Bytes with no signature that are also not valid UTF-8, so they cannot be
  mistaken for a path → `:not_an_image`.

  Note that a *valid-UTF-8* no-signature blob is a path candidate under the
  path-first rule and reports a file error instead; use `{:bytes, _}` to force
  the sniff.
  """
  def no_signature, do: <<0xDE, 0xAD, 0xBE, 0xEF>>
end
