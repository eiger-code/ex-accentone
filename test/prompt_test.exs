defmodule Accentone.PromptTest do
  use ExUnit.Case, async: true

  alias Accentone.Prompt

  # The prompt wording pinned as exact strings. The canonical code blocks wrap
  # at ~80 columns for readability; the generated prompts normalize each
  # paragraph (and each rubric bullet) to one line, so the fixtures below are the
  # same wording unwrapped. The count is a parameter rather than a literal in the
  # two-role fixtures so the non-uniform case pins that each role's own limit
  # rides on its own line.
  #
  # The four non-inlined role descriptions are pinned by containment, because
  # only `key_colors` and `accent_colors` appear in the canonical block.

  @two_role_counts %{key: 3, accent: 3}

  defp ok(kind, colors, counts) do
    case Prompt.build(kind, colors, counts) do
      {:ok, prompt} -> prompt
      {:error, reason} -> flunk("expected a prompt, got #{inspect(reason)}")
    end
  end

  defp error(kind, colors, counts) do
    case Prompt.build(kind, colors, counts) do
      {:error, reason} -> reason
      {:ok, prompt} -> flunk("expected an error, got #{inspect(prompt)}")
    end
  end

  defp order(text, needle), do: elem(:binary.match(text, needle), 0)

  defp default_key_accent(key_count, accent_count) do
    "Analyze this image and extract an ordered palette of colors for the requested " <>
      "roles.\n\n" <>
      "Return a JSON object with exactly these keys:\n\n" <>
      "{\n" <>
      ~s|  "key_colors": [\n| <>
      ~s|    {"hex": "3A6EA5", "confidence": 0.87}\n| <>
      "  ],\n" <>
      ~s|  "accent_colors": [\n| <>
      ~s|    {"hex": "FFB000", "confidence": 0.72}\n| <>
      "  ]\n" <>
      "}\n\n" <>
      "key_colors (at most #{key_count} colors, ordered most to least important): " <>
      "The colors that define the emotional tone, theme, or subject of the image, " <>
      "regardless of how much area they cover. Consider these psychological and " <>
      "emotional factors:\n" <>
      "- Warm/cool temperature: Reds/oranges/yellows (warm, energetic, passionate) " <>
      "vs blues/greens (cool, calm, professional)\n" <>
      "- Mood and atmosphere: Bright colors (joyful, optimistic) vs dark colors " <>
      "(serious, mysterious)\n" <>
      "- Brand association: Luxury (gold, black), nature (greens, earth tones), " <>
      "technology (blues, silvers)\n" <>
      "- Cultural symbolism: Red (luck, celebration in some cultures), white " <>
      "(purity, peace), black (elegance, power)\n" <>
      "- Overall emotional impact: Does the color evoke trust, excitement, " <>
      "serenity, or urgency?\n\n" <>
      "accent_colors (at most #{accent_count} colors, ordered most to least important): " <>
      "Colors used sparingly but with high visual impact; they draw attention and " <>
      "create contrast. These are often highlights, text, small objects, or focal " <>
      "points that stand out from the dominant color.\n\n" <>
      "Omit a role, or return fewer colors for it, rather than repeating a color or " <>
      "padding the list with a near-duplicate. Each distinct color belongs under only " <>
      "one role; if it qualifies for several, put it under the single best fit.\n\n" <>
      ~s|Color format: each "hex" must be exactly 6 hexadecimal digits (0-9, A-F), | <>
      ~s|uppercase, with no leading "#". Do not return color names, rgb() values, or | <>
      "any other format.\n\n" <>
      "confidence: For each color, a number from 0.3 to 1.0 expressing how strongly " <>
      "the image supports that color for that role. If you would score a color below " <>
      "0.3, omit it instead of listing it:\n" <>
      "- 0.90 and above: Extremely confident - the color is highly prominent and " <>
      "unambiguous\n" <>
      "- 0.70 to below 0.90: Very confident - the color is clearly present and " <>
      "well-defined\n" <>
      "- 0.50 to below 0.70: Moderately confident - the color is present but may " <>
      "have variations\n" <>
      "- 0.30 to below 0.50: Low confidence - the color is subtle or context-dependent" <>
      "\n\n" <>
      "Respond with the JSON object only. Do not include explanations, commentary, or " <>
      "markdown code fences."
  end

  defp terse_key_accent(key_count, accent_count) do
    "Extract colors from this image. Return a JSON object with exactly these keys:\n" <>
      "key_colors\n" <>
      "accent_colors\n\n" <>
      "Each value is an array of objects of exactly this shape: " <>
      ~s|{"hex": "3A6EA5", "confidence": 0.87}, ordered from most to least | <>
      "important.\n\n" <>
      "key_colors (at most #{key_count} colors, ordered most to least important): " <>
      "The colors that define the emotional tone, theme, or subject of the image, " <>
      "regardless of how much area they cover.\n" <>
      "accent_colors (at most #{accent_count} colors, ordered most to least important): " <>
      "Colors used sparingly but with high visual impact; they draw attention and " <>
      "create contrast. These are often highlights, text, small objects, or focal " <>
      "points that stand out from the dominant color.\n\n" <>
      "Hex must be exactly 6 hexadecimal digits (0-9, A-F), uppercase, with no " <>
      "leading \"#\". Omit a role, or return fewer colors for it, rather than " <>
      "repeating a color or padding the list. Respond with the JSON object only."
  end

  describe "build/3: :default" do
    test "pins the canonical two-role prompt" do
      assert ok(:default, [:key, :accent], @two_role_counts) == default_key_accent(3, 3)
    end

    test "a non-uniform count puts each role's own limit on its own line" do
      prompt = ok(:default, [:key, :accent], %{key: 1, accent: 7})

      assert prompt == default_key_accent(1, 7)
      assert prompt =~ "key_colors (at most 1 colors, ordered most to least important)"
      assert prompt =~ "accent_colors (at most 7 colors, ordered most to least important)"
      refute prompt =~ "key_colors (at most 7 colors"
    end

    test "role order follows colors:, not the canonical vocabulary order" do
      prompt = ok(:default, [:accent, :key], @two_role_counts)

      assert order(prompt, "\"accent_colors\"") < order(prompt, "\"key_colors\"")
      assert order(prompt, "accent_colors (at most") < order(prompt, "key_colors (at most")
    end

    test "the four non-inlined roles use the description blocks verbatim" do
      prompt =
        ok(:default, [:background, :surface, :muted, :highlight], %{
          background: 3,
          surface: 3,
          muted: 3,
          highlight: 3
        })

      assert prompt =~
               "background_colors (at most 3 colors, ordered most to least important): " <>
                 "The dominant field the subject sits on: the colors that fill the largest " <>
                 "area behind and around the subject. This block is about coverage, not " <>
                 "importance. A large flat backdrop belongs here even if it is dull; a small " <>
                 "vivid object never does, because that is accent_colors."

      assert prompt =~
               "surface_colors (at most 3 colors, ordered most to least important): " <>
                 "The neutral material tone the image implies rather than shows: the color a " <>
                 "physical object in this image would be made of, or the base color a designer " <>
                 "would extend the image's edges into. It is the quieter, slightly duller " <>
                 "neighbour of background_colors. When choosing between the two, the one that " <>
                 "could be tiled across a large flat area is surface_colors, and the one the " <>
                 "subject is photographed against is background_colors. Do not return the same " <>
                 "color under both."

      assert prompt =~
               "muted_colors (at most 3 colors, ordered most to least important): " <>
                 "The desaturated, low-chroma counterpart of the dominant color: the same hue " <>
                 "family as key_colors with saturation pulled toward grey — grey-blue where " <>
                 "the key is blue, dusty rose where the key is red. Do not return a fully " <>
                 "neutral grey unless the key color is itself neutral."

      assert prompt =~
               "highlight_colors (at most 3 colors, ordered most to least important): " <>
                 "The brightest or most luminous meaningful tone: specular highlights, light " <>
                 "sources, sunlit faces, paper or screen white. Distinct from accent_colors, " <>
                 "which is about contrast against the field even when the accent is dark: a " <>
                 "deep navy accent is accent_colors, a blown-out white is highlight_colors."
    end

    test "the example object carries one entry per requested role" do
      prompt =
        ok(:default, Prompt.roles(), %{
          key: 3,
          accent: 3,
          background: 3,
          surface: 3,
          muted: 3,
          highlight: 3
        })

      for field <- ~w[key_colors accent_colors background_colors surface_colors
                      muted_colors highlight_colors] do
        assert prompt =~ "\"#{field}\": [\n"
      end
    end
  end

  describe "build/3: :terse" do
    test "pins the two-role template with per-role counts substituted" do
      assert ok(:terse, [:key, :accent], @two_role_counts) == terse_key_accent(3, 3)
    end

    test "carries a non-uniform count per role and drops the rubric" do
      prompt = ok(:terse, [:key, :accent], %{key: 1, accent: 3})

      assert prompt == terse_key_accent(1, 3)
      assert prompt =~ "key_colors (at most 1 colors, ordered most to least important)"
      # The rubric and the scoring bands are what `:terse` removes.
      refute prompt =~ "Warm/cool temperature"
      refute prompt =~ "0.90 and above"
      refute prompt =~ "confidence: For each color"
    end

    test "one description line per role, in colors: order" do
      prompt = ok(:terse, [:accent, :key], @two_role_counts)

      assert order(prompt, "accent_colors (at most") < order(prompt, "key_colors (at most")
    end
  end

  describe "build/3: custom binaries" do
    test "a caller binary is used exactly as supplied" do
      custom = "Extract key_colors and accent_colors. Six uppercase hex digits, no #."
      assert ok(custom, [:key, :accent], @two_role_counts) == custom
    end

    test "only requested roles are required" do
      assert ok("return key_colors", [:key], %{key: 1}) == "return key_colors"

      assert error("return key_colors", [:key, :accent], @two_role_counts) ==
               {:invalid_option, :prompt, {:missing_role_key, :accent_colors}}
    end
  end

  describe "build/3: the JSON-only instruction" do
    test "does not append when json is already a whole token, any case" do
      for word <- ["json", "JSON", "Json", "JSON-only.", "(json)"] do
        custom = "Extract key_colors and accent_colors as #{word}."

        assert ok(custom, [:key, :accent], @two_role_counts) == custom
      end
    end

    # The instruction rides on the library's templates, so a custom binary never
    # gains it — the same contract `build/3: custom binaries` pins from the other
    # side.
    test "a custom binary is never given the instruction" do
      for custom <- [
            "Extract key_colors and accent_colors. Six uppercase hex digits.",
            "key_colors accent_colors, output jsonl",
            "key_colors accent_colors, key json_object"
          ] do
        assert ok(custom, [:key, :accent], @two_role_counts) == custom
      end
    end

    # The guard is what keeps a stock prompt from collecting a second sentence
    # saying what the template already said — both templates end with their own
    # JSON-only sentence, so the assertion is that there is exactly one.
    test "both stock prompts already satisfy the guard" do
      for kind <- [:default, :terse] do
        prompt = ok(kind, [:key, :accent], @two_role_counts)

        assert prompt =~ ~r/\bjson\b/i
        assert length(String.split(prompt, "Respond with the JSON object only.")) == 2
      end
    end
  end

  describe "build/3: the pre-flight role-key check" do
    test "a missing field name is {:missing_role_key, field}" do
      assert error("return colors as JSON", [:key], %{key: 3}) ==
               {:invalid_option, :prompt, {:missing_role_key, :key_colors}}
    end

    test "Key_Colors, key_colors_extra, and not_key_colors fail; key_colors passes" do
      for bad <- ["Key_Colors", "key_colors_extra", "not_key_colors"] do
        assert error("return #{bad} as JSON", [:key], %{key: 3}) ==
                 {:invalid_option, :prompt, {:missing_role_key, :key_colors}}
      end

      assert ok("return key_colors as JSON", [:key], %{key: 3}) == "return key_colors as JSON"
    end

    test "every requested role is checked, in colors: order" do
      assert error("only accent_colors here", [:key, :accent], @two_role_counts) ==
               {:invalid_option, :prompt, {:missing_role_key, :key_colors}}
    end

    test "the appended instruction does not repair a missing role key" do
      assert error("return colors only", [:key], %{key: 1}) ==
               {:invalid_option, :prompt, {:missing_role_key, :key_colors}}
    end

    test "the stock :terse prompt names every requested role" do
      colors = Prompt.roles()
      counts = Map.new(colors, &{&1, 3})

      assert {:ok, prompt} = Prompt.build(:terse, colors, counts)

      for role <- colors do
        assert prompt =~ to_string(Prompt.field(role))
      end
    end

    test "an unknown kind is {:invalid_option, :prompt, kind}" do
      assert error(:verbose, [:key], %{key: 3}) == {:invalid_option, :prompt, :verbose}
    end
  end
end
