defmodule Accentone.PaletteTest do
  use ExUnit.Case, async: true

  alias Accentone.Color
  alias Accentone.Palette
  alias Accentone.Prompt

  doctest Accentone.Palette

  # The six-row role/field table lives in `Accentone.Prompt` exactly once; these
  # are the tests that pin the vocabulary, the mapping, and `get/2`'s three
  # outcomes.

  describe "the role vocabulary" do
    test "roles/0 is the six built-in roles in canonical order" do
      assert Prompt.roles() == [:key, :accent, :background, :surface, :muted, :highlight]
    end

    test "field/1 maps each role to its struct field" do
      assert Enum.map(Prompt.roles(), &Prompt.field/1) == [
               :key_colors,
               :accent_colors,
               :background_colors,
               :surface_colors,
               :muted_colors,
               :highlight_colors
             ]
    end

    test "field/1 raises ArgumentError outside the six roles" do
      for bad <- [:key_color, :colors, :roles, :key_colors, "key", nil, 1] do
        assert_raise ArgumentError, "unknown color role: #{inspect(bad)}", fn ->
          Prompt.field(bad)
        end
      end
    end
  end

  describe "get/2" do
    test "returns the requested role's list" do
      palette = %Palette{roles: [:key], key_colors: [%Color{hex: "#3A6EA5", confidence: nil}]}

      assert Palette.get(palette, :key) == [%Color{hex: "#3A6EA5", confidence: nil}]
    end

    test "returns [] for a known but unrequested role" do
      palette = %Palette{roles: [:key]}

      assert Palette.get(palette, :background) == []
      assert Palette.get(palette, :accent) == []
      assert Palette.get(palette, :highlight) == []
    end

    test "returns [] for a requested-but-empty role, indistinguishably from nil" do
      palette = %Palette{roles: [:key], key_colors: []}

      assert Palette.get(palette, :key) == []
    end

    test "raises ArgumentError for an atom outside the six roles" do
      palette = %Palette{roles: [:key]}

      assert_raise ArgumentError, fn -> Palette.get(palette, :key_color) end
      assert_raise ArgumentError, fn -> Palette.get(palette, :roles) end
    end

    test "generic iteration over roles/1 and get/2 is total" do
      palette = %Palette{
        roles: [:accent, :key, :muted],
        key_colors: [%Color{hex: "#3A6EA5", confidence: nil}],
        accent_colors: [],
        muted_colors: nil
      }

      got =
        for role <- Palette.roles(palette),
            color <- Palette.get(palette, role) do
          {role, color.hex}
        end

      assert got == [{:key, "#3A6EA5"}]
    end
  end

  describe "roles/1" do
    test "returns the requested roles in the caller's order, not canonical order" do
      assert Palette.roles(%Palette{roles: [:accent, :key, :muted]}) == [:accent, :key, :muted]
    end

    test "defaults to [] and is never nil" do
      assert Palette.roles(%Palette{}) == []
    end
  end
end
