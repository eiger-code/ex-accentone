defmodule Accentone.ParserTest do
  use ExUnit.Case, async: true

  alias Accentone.Color
  alias Accentone.Parser

  # Parse steps 1–5. The parser consumes exactly what `Accentone.Client.call/4`
  # returns, so every row builds that map by hand and no stub is involved — the
  # stub-driven variants live in the pipeline conformance sweep. Every row here
  # leaves `:object` nil, which is the fallback path: it is what a provider that
  # does not enforce the schema produces, and what a fenced or prose-wrapped
  # reply produces even when one does. The rules being pinned:
  #
  #   * the parse order (truncation beats object beats content beats decode beats
  #     roles);
  #   * one row per line of the normalization table;
  #   * the string-aware outermost-object scanner;
  #   * `:drop` being entry-level only;
  #   * per-list dedup (never across roles) and per-role truncation;
  #   * no reply shape raising `ArgumentError`/`FunctionClauseError`/
  #     `BadMapError`.

  @key [:key]
  @key_counts %{key: 3}
  @key_accent [:key, :accent]
  @key_accent_counts %{key: 3, accent: 3}

  @valid_entry %{"hex" => "#3A6EA5"}

  defp parse(content, opts \\ []) do
    Parser.parse(
      %{
        object: Keyword.get(opts, :object),
        content: content,
        finish_reason: Keyword.get(opts, :finish_reason, :stop),
        usage: Keyword.get(opts, :usage, %{total_tokens: 1})
      },
      Keyword.get(opts, :colors, @key),
      Keyword.get(opts, :counts, @key_counts),
      Keyword.get(opts, :on_invalid_color, :error)
    )
  end

  # `parse` over a JSON-encoded object, the shape almost every row uses.
  defp parse_object(map, opts \\ []), do: parse(Jason.encode!(map), opts)

  defp fields(map, opts \\ []) do
    assert {:ok, %{fields: fields}} = parse_object(map, opts)
    fields
  end

  defp one_color(entry) do
    assert {:ok, %{fields: %{key_colors: [color]}}} =
             parse_object(%{"key_colors" => [entry]})

    color
  end

  # A `key_colors` value with `accent_colors` populated, so a legitimately empty
  # `key_colors` is observable instead of collapsing to `:no_colors`.
  defp key_colors_with_accent(key_value) do
    assert {:ok, %{fields: %{key_colors: list}}} =
             parse_object(
               %{"key_colors" => key_value, "accent_colors" => [%{"hex" => "#FFB000"}]},
               colors: @key_accent,
               counts: @key_accent_counts
             )

    list
  end

  defp hexes(colors), do: Enum.map(colors, & &1.hex)

  describe "step 1: finish_reason" do
    test ":length is truncation, checked before the object and the content" do
      body = Jason.encode!(%{"key_colors" => [@valid_entry]})

      assert parse(body, finish_reason: :length) == {:error, {:truncated, :length}}
      # Unparseable content still reports truncation, which is the order claim.
      assert parse(nil, finish_reason: :length) == {:error, {:truncated, :length}}
      assert parse("not json", finish_reason: :length) == {:error, {:truncated, :length}}
      # A recovered object does not rescue a truncated reply either.
      assert parse(nil, finish_reason: :length, object: %{"key_colors" => [@valid_entry]}) ==
               {:error, {:truncated, :length}}
    end

    test "every other value proceeds to the object and the content" do
      body = Jason.encode!(%{"key_colors" => [@valid_entry]})

      for reason <- [:stop, :content_filter, :tool_calls, :cancelled, nil, "stop", 123, [], %{}] do
        assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5", confidence: nil}]}}} =
                 parse(body, finish_reason: reason)
      end
    end
  end

  describe "step 2: the recovered object" do
    test "an object is the whole answer and the content is not consulted" do
      object = %{"key_colors" => [%{"hex" => "#3A6EA5", "confidence" => 0.87}]}

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5", confidence: 0.87}]}}} =
               parse("this content is irrelevant", object: object)
    end

    test "a recovered object beats content that would fail on its own" do
      object = %{"key_colors" => [@valid_entry]}

      # `nil` content alone is `{:content, :null}`; the object rescues it.
      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} =
               parse(nil, object: object)

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} =
               parse("not json at all", object: object)
    end

    test "a non-map object falls through to the decoder" do
      body = Jason.encode!(%{"key_colors" => [@valid_entry]})

      for object <- [nil, "{}", [], 42] do
        assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} =
                 parse(body, object: object)
      end
    end
  end

  describe "step 3: content" do
    test "a JSON string is used as-is" do
      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} =
               parse(Jason.encode!(%{"key_colors" => [@valid_entry]}))
    end

    test "a parts list joins its text parts, in order, ignoring everything else" do
      parts = [
        %{"type" => "image_url", "image_url" => %{}},
        %{"type" => "text", "text" => "{\"key_co"},
        "not a map",
        %{"type" => "text", "text" => "lors\":[{\"hex\":\"#3A6EA5\"}]}"},
        %{"type" => "text", "text" => 123},
        %{"type" => "other", "text" => "ignored"}
      ]

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(parts)
    end

    test "a parts list with no text part joins to \"\" and has no object" do
      assert parse([%{"type" => "image_url", "image_url" => %{}}]) ==
               {:error, {:invalid_json, :no_object}}

      assert parse([]) == {:error, {:invalid_json, :no_object}}
    end

    test "null is `{:content, :null}`" do
      assert parse(nil) == {:error, {:invalid_response, {:content, :null}}}
    end

    test "anything else is `{:content, :not_a_string}`" do
      for bad <- [123, 1.5, true, false, %{"a" => 1}, {:ok, "x"}, :atom] do
        assert parse(bad) == {:error, {:invalid_response, {:content, :not_a_string}}}
      end
    end
  end

  describe "step 3, continued: fences and decode" do
    test "strips a ```json fence" do
      fenced = "```json\n" <> Jason.encode!(%{"key_colors" => [@valid_entry]}) <> "\n```"

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(fenced)
    end

    test "strips a bare ``` fence" do
      fenced = "```\n" <> Jason.encode!(%{"key_colors" => [@valid_entry]}) <> "\n```"

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(fenced)
    end

    test "decodes an object surrounded by prose" do
      text = "Sure! Here it is: " <> Jason.encode!(%{"key_colors" => [@valid_entry]}) <> " done."

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(text)
    end

    test "a brace inside a JSON string does not truncate the candidate" do
      # A naive brace counter stops at the `}` inside `"a}b"` and decodes a
      # malformed prefix — this pins the string-aware scanner.
      text = ~s(prose {"key_colors":[{"hex":"#3A6EA5","note":"a}b"}]} tail)

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(text)
    end

    test "an escaped quote inside a string does not end it early" do
      body = Jason.encode!(%{"key_colors" => [%{"hex" => "#3A6EA5", "note" => "a\"}b"}]})
      text = "prefix " <> body <> " suffix"

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(text)
    end

    test "skips an unbalanced brace in prose and finds the later object" do
      text = ~s(a stray { here and the real one {"key_colors":[{"hex":"#3A6EA5"}]})

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(text)
    end

    test "a long run of unmatched braces is scanned once, not once per brace" do
      # Every stray `{` used to be a start candidate that re-read the whole tail,
      # which is quadratic: 20 000 of them took about a second. The single pass
      # finds the one real object and stays linear, so the budget below is two
      # orders of magnitude of headroom rather than a tuned threshold.
      text = String.duplicate("{", 20_000) <> ~s({"key_colors":[{"hex":"#3A6EA5"}]})

      {micros, result} = :timer.tc(fn -> parse(text) end)

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = result
      assert micros < 250_000, "the brace scan took #{micros} µs; it should be linear"
    end

    test "a decoded non-object is `:not_an_object`" do
      for text <- ["[]", "[1,2]", "\"str\"", "123", "true", "null"] do
        assert parse(text) == {:error, {:invalid_response, :not_an_object}}
      end

      # Valid object *inside* an array: extraction finds `{...}` only when the
      # whole-string decode fails, so a bare array reports the array.
      assert parse("[{\"key_colors\":[]}]") == {:error, {:invalid_response, :not_an_object}}
    end

    test "no balanced object is `{:invalid_json, :no_object}`" do
      for text <- ["", "   ", "no json here", "{\"unclosed\":", "{", "}", "} then {"] do
        assert parse(text) == {:error, {:invalid_json, :no_object}}
      end
    end

    test "a balanced but undecodable object is `{:invalid_json, :malformed}`" do
      for text <- ["{not json}", "{\"a\":}", "{\"a\" 1}", "{\"key_colors\": [}"] do
        assert parse(text) == {:error, {:invalid_json, :malformed}}
      end
    end

    test "neither invalid_json payload carries the content" do
      assert {:error, {:invalid_json, :no_object}} = parse("secret prose about the image")
      assert {:error, {:invalid_json, :malformed}} = parse("{\"a\": } secret prose")
    end
  end

  describe "step 5: the normalization table" do
    test "hex is normalized to uppercase #RRGGBB" do
      for {raw, expected} <- [
            {"#3a6ea5", "#3A6EA5"},
            {"3a6ea5", "#3A6EA5"},
            {" 3A6EA5 ", "#3A6EA5"},
            {"#3A6EA5", "#3A6EA5"},
            {"\t#3a6ea5\n", "#3A6EA5"}
          ] do
        assert one_color(%{"hex" => raw}).hex == expected
      end
    end

    test "malformed hex fails the whole call with the raw value" do
      for raw <- ["3A6EA5FF", "#ABC", "steel blue", "", "#", "#3A6EA", "##3A6EA5"] do
        assert parse_object(%{"key_colors" => [%{"hex" => raw}]}) ==
                 {:error, {:invalid_color, {:key_colors, 0}, raw}}
      end
    end

    test "a non-string hex is an invalid_color, not a crash" do
      for raw <- [123, nil, true, ["#3A6EA5"], %{"a" => 1}] do
        assert parse_object(%{"key_colors" => [%{"hex" => raw}]}) ==
                 {:error, {:invalid_color, {:key_colors, 0}, raw}}
      end
    end

    test "a missing hex is its own member, with the index" do
      assert parse_object(%{"key_colors" => [%{}]}) ==
               {:error, {:missing_field, {:key_colors, 0}, "hex"}}

      assert parse_object(%{"key_colors" => [@valid_entry, %{"name" => "x"}]}) ==
               {:error, {:missing_field, {:key_colors, 1}, "hex"}}
    end

    test "confidence is coerced and clamped, or degrades to nil" do
      for {raw, expected} <- [
            {1.4, 1.0},
            {1, 1.0},
            {0, 0.0},
            {0.87, 0.87},
            {"0.8", 0.8},
            {" 0.8 ", 0.8},
            {"1", 1.0},
            {-0.5, 0.0},
            {"1.4", 1.0},
            {"high", nil},
            {"0.8x", nil},
            {"", nil},
            {true, nil},
            {false, nil},
            {nil, nil},
            {%{}, nil},
            {[0.8], nil}
          ] do
        entry = Map.put(%{"hex" => "#3A6EA5"}, "confidence", raw)
        assert one_color(entry).confidence == expected
      end
    end

    test "a missing confidence is nil" do
      assert one_color(@valid_entry).confidence == nil
    end

    test "a role-level non-list fails, even for `null`-like shapes" do
      for bad <- ["3A6EA5", 5, 1.5, true, %{"a" => 1}, %{}] do
        assert parse_object(%{"key_colors" => bad}) ==
                 {:error, {:invalid_response, {:key_colors, :not_a_list}}}
      end
    end

    test "an entry that is not an object is the three-tuple member" do
      for bad <- ["3A6EA5", 5, 1.5, nil, true, []] do
        assert parse_object(%{"key_colors" => [bad]}) ==
                 {:error, {:invalid_response, {:key_colors, 0, :not_an_object}}}
      end

      assert parse_object(%{"key_colors" => [@valid_entry, "3A6EA5"]}) ==
               {:error, {:invalid_response, {:key_colors, 1, :not_an_object}}}
    end

    test "unknown entry keys are ignored" do
      entry = %{"hex" => "#3A6EA5", "name" => "blue", "rgb" => [58, 110, 165]}

      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5", confidence: nil}]}}} =
               parse_object(%{"key_colors" => [entry]})
    end

    test "a volunteered, unrequested role is ignored and absent from fields" do
      map = %{
        "key_colors" => [@valid_entry],
        "highlight_colors" => [%{"hex" => "#FFFFFF"}]
      }

      parsed = fields(map)
      assert Map.keys(parsed) == [:key_colors]
      assert hexes(parsed.key_colors) == ["#3A6EA5"]
    end

    test "missing, explicit null, and empty role values are all []" do
      assert key_colors_with_accent(nil) == []
      assert key_colors_with_accent([]) == []

      parsed =
        fields(%{"accent_colors" => [%{"hex" => "#FFB000"}]},
          colors: @key_accent,
          counts: @key_accent_counts
        )

      assert parsed.key_colors == []
      assert hexes(parsed.accent_colors) == ["#FFB000"]
    end

    test "every requested role empty is `:no_colors`" do
      assert parse_object(%{}) == {:error, {:invalid_response, :no_colors}}
      assert parse_object(%{"key_colors" => []}) == {:error, {:invalid_response, :no_colors}}
      assert parse_object(%{"key_colors" => nil}) == {:error, {:invalid_response, :no_colors}}

      assert parse_object(%{"accent_colors" => [%{"hex" => "#FFB000"}]}) ==
               {:error, {:invalid_response, :no_colors}}
    end

    test "the success value is exactly fields/dropped/dropped_by_field, keyed by field" do
      assert parse_object(%{"key_colors" => [@valid_entry]}) ==
               {:ok,
                %{
                  fields: %{key_colors: [%Color{hex: "#3A6EA5", confidence: nil}]},
                  dropped: 0,
                  dropped_by_field: %{}
                }}
    end
  end

  describe "step 5: dedup and truncation" do
    test "collapses exact duplicates within a list, keeping the first" do
      entries = [
        %{"hex" => "#3A6EA5", "confidence" => 0.9},
        %{"hex" => "#3a6ea5"},
        %{"hex" => "#FFB000"}
      ]

      assert {:ok, %{fields: %{key_colors: list}}} =
               parse_object(%{"key_colors" => entries})

      assert list == [
               %Color{hex: "#3A6EA5", confidence: 0.9},
               %Color{hex: "#FFB000", confidence: nil}
             ]
    end

    test "dedup happens before truncation" do
      entries =
        for hex <- ["#111111", "#111111", "#222222", "#333333"], do: %{"hex" => hex}

      assert {:ok, %{fields: %{key_colors: list}}} =
               parse_object(%{"key_colors" => entries}, counts: %{key: 3})

      assert hexes(list) == ["#111111", "#222222", "#333333"]
    end

    test "retains the same hex across roles" do
      map = %{
        "key_colors" => [%{"hex" => "#3A6EA5"}],
        "accent_colors" => [%{"hex" => "#3a6ea5"}]
      }

      assert {:ok, %{fields: %{key_colors: [key], accent_colors: [accent]}}} =
               parse_object(map, colors: @key_accent, counts: @key_accent_counts)

      assert key.hex == "#3A6EA5"
      assert accent.hex == "#3A6EA5"
    end

    test "truncates each list to that role's own count" do
      key = for hex <- ~w(#111111 #222222 #333333 #444444 #555555), do: %{"hex" => hex}
      accent = for hex <- ~w(#AAAAAA #BBBBBB #CCCCCC #DDDDDD), do: %{"hex" => hex}

      assert {:ok, %{fields: %{key_colors: k, accent_colors: a}}} =
               parse_object(
                 %{"key_colors" => key, "accent_colors" => accent},
                 colors: @key_accent,
                 counts: %{key: 2, accent: 3}
               )

      assert hexes(k) == ["#111111", "#222222"]
      assert hexes(a) == ["#AAAAAA", "#BBBBBB", "#CCCCCC"]
    end

    test "a short list is accepted" do
      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} =
               parse_object(%{"key_colors" => [@valid_entry]}, counts: %{key: 3})
    end
  end

  describe ":on_invalid_color :drop" do
    test "drops an invalid_color entry and keeps the rest" do
      entries = [%{"hex" => "#3A6EA5"}, %{"hex" => "#ABC"}, %{"hex" => "#FFB000"}]

      assert {:ok, %{fields: %{key_colors: list}, dropped: 1, dropped_by_field: %{key_colors: 1}}} =
               parse_object(%{"key_colors" => entries}, on_invalid_color: :drop)

      assert hexes(list) == ["#3A6EA5", "#FFB000"]
    end

    test "drops a missing_field entry" do
      entries = [@valid_entry, %{"name" => "x"}]

      assert {:ok,
              %{
                fields: %{key_colors: [%Color{hex: "#3A6EA5"}]},
                dropped: 1,
                dropped_by_field: %{key_colors: 1}
              }} =
               parse_object(%{"key_colors" => entries}, on_invalid_color: :drop)
    end

    test "drops a non-object entry without failing the role" do
      entries = ["3A6EA5", @valid_entry]

      assert {:ok,
              %{
                fields: %{key_colors: [%Color{hex: "#3A6EA5"}]},
                dropped: 1,
                dropped_by_field: %{key_colors: 1}
              }} =
               parse_object(%{"key_colors" => entries}, on_invalid_color: :drop)
    end

    test "never drops across roles: the per-field breakdown is separate" do
      map = %{
        "key_colors" => [%{"hex" => "#ABC"}],
        "accent_colors" => [%{"hex" => "#FFB000"}, 5]
      }

      assert {:ok,
              %{
                fields: %{key_colors: [], accent_colors: [%Color{hex: "#FFB000"}]},
                dropped: 2,
                dropped_by_field: %{key_colors: 1, accent_colors: 1}
              }} =
               parse_object(map,
                 colors: @key_accent,
                 counts: @key_accent_counts,
                 on_invalid_color: :drop
               )
    end

    test "a role-level non-list still fails" do
      assert parse_object(%{"key_colors" => "3A6EA5"}, on_invalid_color: :drop) ==
               {:error, {:invalid_response, {:key_colors, :not_a_list}}}
    end

    test "content-level and payload-level shapes still fail" do
      assert parse(nil, on_invalid_color: :drop) ==
               {:error, {:invalid_response, {:content, :null}}}

      assert parse("pure prose", on_invalid_color: :drop) ==
               {:error, {:invalid_json, :no_object}}

      assert parse("[1,2]", on_invalid_color: :drop) ==
               {:error, {:invalid_response, :not_an_object}}

      assert parse("{\"a\":}", on_invalid_color: :drop) ==
               {:error, {:invalid_json, :malformed}}
    end

    test "a role emptied by drops is [], and an all-dropped palette is :no_colors" do
      map = %{"key_colors" => [%{"hex" => "#ABC"}], "accent_colors" => [%{"hex" => "#FFB000"}]}

      assert {:ok, %{fields: %{key_colors: [], accent_colors: [%Color{hex: "#FFB000"}]}}} =
               parse_object(map,
                 colors: @key_accent,
                 counts: @key_accent_counts,
                 on_invalid_color: :drop
               )

      assert parse_object(%{"key_colors" => [%{"hex" => "#ABC"}]}, on_invalid_color: :drop) ==
               {:error, {:invalid_response, :no_colors}}
    end

    test "strict mode (the default) fails on the first bad entry" do
      assert parse_object(%{"key_colors" => [%{"hex" => "#ABC"}]}) ==
               {:error, {:invalid_color, {:key_colors, 0}, "#ABC"}}
    end

    test "a clean response reports no drops" do
      assert {:ok, %{dropped: 0, dropped_by_field: %{}}} =
               parse_object(%{"key_colors" => [@valid_entry]}, on_invalid_color: :drop)
    end
  end

  # `usage` is carried on the client's result and not read here; the pipeline's
  # telemetry reads it. This pins that it stays an ignored key rather than
  # growing into an input by accident.
  describe "the usage passthrough" do
    test "usage never changes the result" do
      body = Jason.encode!(%{"key_colors" => [@valid_entry]})

      assert parse(body, usage: nil) == parse(body, usage: %{total_tokens: 99})
      assert {:ok, %{fields: %{key_colors: [%Color{hex: "#3A6EA5"}]}}} = parse(body, usage: nil)
    end
  end

  describe "the no-escape rule" do
    test "no response shape raises" do
      contents = [
        nil,
        123,
        1.5,
        true,
        false,
        :atom,
        {:tuple},
        [1, 2],
        [],
        %{},
        %{"a" => 1},
        "",
        "   ",
        "no json",
        "[]",
        "\"str\"",
        "123",
        "true",
        "null",
        "{}",
        "{\"key_colors\":",
        "{not json}",
        "{\"a\":}",
        <<0xFF, 0xFE, ?{, ?}>>,
        Jason.encode!(%{"key_colors" => 5}),
        Jason.encode!(%{"key_colors" => nil}),
        Jason.encode!(%{
          "key_colors" => [
            nil,
            1,
            "x",
            true,
            [],
            %{},
            %{"hex" => nil},
            %{"hex" => 1},
            %{"hex" => "#ABC"},
            @valid_entry
          ]
        }),
        Jason.encode!(%{"key_colors" => [%{"hex" => "#3A6EA5", "confidence" => [1, 2]}]}),
        Jason.encode!(%{"key_colors" => [%{"hex" => "#3A6EA5", "confidence" => %{}}]}),
        [%{"type" => "text", "text" => Jason.encode!(%{"key_colors" => [@valid_entry]})}],
        [%{"type" => "text", "text" => 5}, {"not", "a map"}]
      ]

      finish_reasons = [:length, :stop, :content_filter, :tool_calls, nil, "length", 123, [], %{}]

      # `:object` is swept too: a reply may carry a recovered object, no object,
      # or something that is not a map at all.
      objects = [nil, %{"key_colors" => [@valid_entry]}, %{}, [], "{}", 42]

      for content <- contents,
          reason <- finish_reasons,
          object <- objects,
          mode <- [:error, :drop] do
        result = safe_parse(content, reason, object, mode)

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "expected a tagged tuple for #{inspect(content)} / " <>
                 "#{inspect(reason)} / #{inspect(object)} / #{mode}, got #{inspect(result)}"
      end
    end
  end

  # Catches the exceptions that must not escape for an expected reply shape, so a
  # failure reports the shape instead of a bare crash.
  defp safe_parse(content, finish_reason, object, mode) do
    Parser.parse(
      %{object: object, content: content, finish_reason: finish_reason, usage: nil},
      @key,
      @key_counts,
      mode
    )
  rescue
    exception -> {:raised, exception.__struct__, Exception.message(exception)}
  end
end
