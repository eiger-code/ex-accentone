defmodule Accentone.ErrorTest do
  use ExUnit.Case, async: true

  alias Accentone.Error

  doctest Accentone.Error

  # `message/1` is defined for **every** member of the error taxonomy — a raise
  # that rendered as `inspect(reason)` would defeat the point. One case per
  # member below; the blanket check at the bottom pins "no inspect(reason)
  # fallback".
  #
  # The taxonomy's own table lives in this module's `@moduledoc` — README.md
  # links here for it — so the table is checked against the typespec here too,
  # rather than against a previous draft of itself.

  @taxonomy [
    {:not_an_image, "supported image"},
    {:missing_api_key, "API key"},
    {{:enoent, "photo.jpg"}, "file not found: photo.jpg"},
    {{:eacces, "photo.jpg"}, "permission denied reading file: photo.jpg"},
    {{:eisdir, "photos"}, "expected a file but found a directory: photos"},
    {{:file, :einval, "/dev/zero"}, "could not read file /dev/zero: einval"},
    {{:file, :enametoolong, "aa"}, "could not read file aa: enametoolong"},
    {{:invalid_option, :colors, [:nope]}, "invalid option :colors: [:nope]"},
    {{:image_too_large, 11_000_000}, "image is too large (11000000 bytes)"},
    {{:transport, %Req.TransportError{reason: :timeout}}, "transport error: timeout"},
    {{:truncated, :length}, "truncated"},
    {{:invalid_json, :no_object}, "no JSON object"},
    {{:invalid_json, :malformed}, "malformed JSON"},
    {{:invalid_response, :no_colors}, "no colors for any requested role"},
    {{:invalid_response, :not_an_object}, "was not a JSON object"},
    {{:invalid_response, {:choices, :empty}}, "no usable choices"},
    {{:invalid_response, {:content, :null}}, "no content"},
    {{:invalid_response, {:content, :not_a_string}}, "not a string"},
    {{:invalid_response, {:key_colors, :not_a_list}}, "list of colors for key_colors"},
    {{:invalid_response, {:key_colors, 2, :not_an_object}}, "key_colors entry 2"},
    {{:invalid_response, {:future, :reason}}, "unexpected model response"},
    {{:invalid_color, {:key_colors, 0}, "steel blue"},
     ~s(invalid color at key_colors[0]: "steel blue")},
    {{:missing_field, {:key_colors, 0}, "hex"}, ~s(missing "hex" at key_colors[0])}
  ]

  test "every taxonomy member has its own message clause" do
    for {reason, expected} <- @taxonomy do
      message = Error.message(%Error{reason: reason})

      assert message =~ expected,
             "reason #{inspect(reason)} rendered #{inspect(message)}"
    end
  end

  test "no member falls back to inspect(reason)" do
    for {reason, _expected} <- @taxonomy do
      refute Error.message(%Error{reason: reason}) == inspect(reason)
    end
  end

  test "the reason table in the docs names every member of the taxonomy" do
    table = docs_text() |> table_lines("| reason | what to do |") |> Enum.join("\n")
    tags = reason_tags()

    # Guards against the extraction going quiet: an empty tag list would make
    # the loop below pass without checking anything.
    assert :missing_api_key in tags
    assert length(tags) > 10

    for tag <- tags do
      assert String.contains?(table, ":#{tag}"),
             "the reason table does not mention #{inspect(tag)}"
    end
  end

  test "the reason field is the contract; Exception.message/1 uses the clause" do
    reason = {:invalid_response, :no_colors}
    error = %Error{reason: reason}

    assert error.reason == reason
    assert Exception.message(error) == "model returned no colors for any requested role"
  end

  test "raise/2 carries the reason unchanged" do
    reason = {:http, 429, "slow down"}

    error = assert_raise Error, fn -> raise Error, reason: reason end

    assert error.reason == reason
    assert Exception.message(error) == ~s(request failed with status 429: "slow down")
  end

  test "the http body is head-truncated at 2048 bytes with an ellipsis" do
    assert Error.message(%Error{reason: {:http, 429, "rate limited"}}) ==
             ~s(request failed with status 429: "rate limited")

    rendered = Error.message(%Error{reason: {:http, 500, String.duplicate("x", 4096)}})

    assert rendered =~ "request failed with status 500: "
    # The head (the actionable part) survives in full; the tail does not.
    assert rendered =~ String.duplicate("x", 2048)
    refute rendered =~ String.duplicate("x", 2049)
    assert rendered =~ "..."
  end

  test "rendering an already-truncated body is idempotent" do
    raw = String.duplicate("y", 4096)
    already = binary_part(raw, 0, 2048) <> "..."

    assert Error.message(%Error{reason: {:http, 500, raw}}) ==
             Error.message(%Error{reason: {:http, 500, already}})
  end

  # -- the taxonomy table, read from the published docs ---------------------

  # The compiled docs chunk, which is the text ExDoc publishes. It is read back
  # from the module rather than from `error.ex` itself: the source heredoc's
  # indentation would have to be stripped before a table header could match, and
  # this is the wording a caller actually reads.
  defp docs_text do
    {:docs_v1, _anno, _language, _format, %{"en" => doc}, _metadata, _docs} =
      Code.fetch_docs(Error)

    doc
  end

  defp table_lines(markdown, header) do
    lines = String.split(markdown, "\n")

    case Enum.find_index(lines, &(&1 == header)) do
      nil -> flunk("no table headed #{inspect(header)}")
      start -> lines |> Enum.drop(start) |> Enum.take_while(&String.starts_with?(&1, "|"))
    end
  end

  # `t:Accentone.error_reason/0`, straight from the typespec, so the table is
  # checked against the code's own union rather than against a copy that can
  # drift.
  defp reason_tags do
    types = Accentone |> Code.Typespec.fetch_types() |> elem(1)

    definition =
      Enum.find_value(types, fn
        {_kind, {:error_reason, definition, args}} -> {definition, args}
        _other -> nil
      end)

    case definition do
      nil ->
        flunk("Accentone.error_reason/0 is not exported")

      {definition, args} ->
        {:error_reason, definition, args}
        |> Code.Typespec.type_to_quoted()
        |> unwrap_answer()
        |> union_members()
        |> Enum.map(&tag/1)
    end
  end

  # `type_to_quoted/1` returns the whole `name() :: a | b` answer, so the union
  # is the right-hand side of its `::` node.
  defp unwrap_answer({:"::", _meta, [_name, body]}), do: unwrap_answer(body)
  defp unwrap_answer(body), do: body

  defp union_members({:|, _meta, [left, right]}), do: union_members(left) ++ union_members(right)
  defp union_members(member), do: [member]

  defp tag({:{}, _meta, [name | _rest]}), do: name
  defp tag({name, _rest}) when is_atom(name), do: name
  defp tag(name) when is_atom(name), do: name
end
