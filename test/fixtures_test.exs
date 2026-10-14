defmodule Accentone.FixturesTest do
  use ExUnit.Case, async: true

  alias Accentone.Fixtures

  # The signature table, pinned so the fixtures cannot rot: the sniffing tests
  # that build on them are only as good as these four blobs.
  test "each fixture carries its documented signature" do
    assert <<0xFF, 0xD8, 0xFF, _::binary>> = Fixtures.jpeg()
    assert <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>> = Fixtures.png()
    assert <<"GIF8", _::binary>> = Fixtures.gif()
    assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = Fixtures.webp()
  end

  test "the over-long path fixtures are valid UTF-8 and exceed 4096 bytes" do
    for path <- [Fixtures.over_long_path(), Fixtures.over_long_multibyte_path()] do
      assert String.valid?(path)
      assert byte_size(path) > 4096
      refute String.contains?(path, <<0>>)
    end

    # The rule measures bytes, not characters: the multibyte fixture passes a
    # character-based rule, which is exactly what it is here to catch.
    multibyte = Fixtures.over_long_multibyte_path()
    assert String.length(multibyte) < 4096
    assert byte_size(multibyte) > 4096
  end

  test "the collision fixtures really do look like image signatures" do
    assert <<"GIF8", _::binary>> = Fixtures.gif_shaped_path()
    assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = Fixtures.webp_shaped_path()
  end

  test "the NUL and no-signature fixtures are what the classifier turns on" do
    nul = Fixtures.nul_path()
    assert String.valid?(nul)
    assert String.contains?(nul, <<0>>)

    # Not valid UTF-8, so it can never be mistaken for a candidate path.
    refute String.valid?(Fixtures.no_signature())
  end
end
