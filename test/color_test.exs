defmodule Accentone.ColorTest do
  use ExUnit.Case, async: true

  alias Accentone.Color

  doctest Accentone.Color

  # `valid?/1` reports whether a hand-built `%Color{}` satisfies the table,
  # so a typo in a caller's fixture fails an assertion on the value instead of
  # silently differing from what the library would return. One case per
  # rejection below.

  describe "valid?/1 accepts" do
    test "uppercase #RRGGBB with a float confidence in 0.0..1.0" do
      assert Color.valid?(%Color{hex: "#3A6EA5", confidence: 0.87})
      assert Color.valid?(%Color{hex: "#000000", confidence: 0.0})
      assert Color.valid?(%Color{hex: "#FFFFFF", confidence: 1.0})
    end

    test "nil confidence — the answer for omitted, null, or non-numeric input" do
      assert Color.valid?(%Color{hex: "#3A6EA5", confidence: nil})
    end

    test "a confidence that defaults in when the field is omitted" do
      assert Color.valid?(%Color{hex: "#3A6EA5"})
    end
  end

  describe "valid?/1 rejects" do
    test "3-digit shorthand" do
      refute Color.valid?(%Color{hex: "#ABC", confidence: nil})
    end

    test "8-digit hex with alpha" do
      refute Color.valid?(%Color{hex: "#3A6EA5FF", confidence: nil})
    end

    test "color names and missing # or lowercase" do
      refute Color.valid?(%Color{hex: "steel blue", confidence: nil})
      refute Color.valid?(%Color{hex: "3A6EA5", confidence: nil})
      refute Color.valid?(%Color{hex: "#3a6ea5", confidence: nil})
    end

    test "surrounding whitespace, including a trailing newline" do
      refute Color.valid?(%Color{hex: " #3A6EA5", confidence: nil})
      refute Color.valid?(%Color{hex: "#3A6EA5 ", confidence: nil})
      # `$` would accept this; the `\z` anchor does not.
      refute Color.valid?(%Color{hex: "#3A6EA5\n", confidence: nil})
    end

    test "a missing or non-string hex" do
      refute Color.valid?(%Color{hex: nil, confidence: nil})
      refute Color.valid?(%Color{hex: 0x3A6EA5, confidence: nil})
    end

    test "an integer confidence — the parser coerces numbers, valid?/1 does not" do
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: 1})
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: 0})
    end

    test "an out-of-range confidence" do
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: -0.1})
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: 1.01})
    end

    test "a non-numeric confidence" do
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: "0.8"})
      refute Color.valid?(%Color{hex: "#3A6EA5", confidence: true})
    end

    test "anything that is not a %Color{}" do
      refute Color.valid?(%{hex: "#3A6EA5", confidence: 0.87})
      refute Color.valid?("#3A6EA5")
      refute Color.valid?(nil)
    end
  end
end
