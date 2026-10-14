defmodule Accentone.Parser do
  @moduledoc false

  # Everything the parser owns once the client has handed over a reply
  # (`Accentone.Client` already did the status, the envelope, and the structured
  # recovery). The order here is fixed, and it is
  # load-bearing:
  #
  #   1. `finish_reason` is `:length` for truncation, checked **before** the
  #      content is looked at, because a half-finished object is far less
  #      actionable than "the cap was too low".
  #   2. The object `ReqLLM` recovered, when there is one. That is the whole reply
  #      for every provider that enforces a schema.
  #   3. Otherwise the fallback decoder: `content` may be a string, a parts list,
  #      or `null`; fences are stripped if present; then the whole thing is
  #      decoded, else the outermost *balanced* `{...}` found by a string- and
  #      escape-aware scanner — a brace inside a JSON string must not truncate the
  #      candidate. This path is not a nicety: a fenced or prose-wrapped reply
  #      carries no recovered object at all, and both work today.
  #   4. Each requested role must be a list (missing/`null` mean `[]`); each
  #      entry must be an object.
  #   5. Normalize hex/confidence, collapse per-list duplicates, truncate each
  #      list to its own count, and reject an entirely empty palette.
  #
  # Two guarantees shape the code below. First, no expected response shape may
  # raise `BadMapError`/`ArgumentError`/`FunctionClauseError`; every access goes
  # through a `case`/`Map.get` with an explicit fallback. Second, only
  # **entry-level** failures are eligible for `:on_invalid_color: :drop`; a
  # role-level (`{field, :not_a_list}`) or payload-level shape still fails the
  # whole call, because "the model broke the schema for a role" must not look
  # like "the image had no such color".

  alias Accentone.Color
  alias Accentone.Prompt

  # `\A`/`\z`, matching `Accentone.Color.valid?/1`: a trailing newline must not
  # validate, since `"3A6EA5\n"` is model drift, not a color.
  @hex ~r/\A[0-9A-F]{6}\z/

  # ```json\n … \n``` and ```\n … \n``` (and a trailing fence with no newline).
  @fence ~r/\A```[^\n]*\n(.*?)\n?```\z/s

  @hex_field "hex"

  @typedoc """
  Per-field dropped-entry counts — `%{}` unless `:drop` discarded something.
  """
  @type dropped_by_field :: %{atom() => non_neg_integer()}

  @typedoc """
  The parser's success value: each requested role's field atom mapped to its
  normalized colors, plus the `:drop` accounting telemetry reports.
  """
  @type result :: %{
          fields: %{atom() => [Color.t()]},
          dropped: non_neg_integer(),
          dropped_by_field: dropped_by_field()
        }

  @doc """
  Turn a reply into normalized per-role color lists.

  `result` is exactly what `Accentone.Client.call/4` returned: the recovered
  `object`, the reply `content`, its `finish_reason`, and its `usage`.
  `colors`/`counts` are the resolved request, so the result holds one field per
  *requested* role and nothing else. `usage` is carried but not read here — the
  client already resolved it for telemetry.

  Returns `{:ok, %{fields: fields, dropped: n, dropped_by_field: %{field => n}}}`
  or `{:error, reason}` from the error-reason taxonomy. No reply shape raises.
  """
  @spec parse(
          Accentone.Client.result(),
          [Accentone.role()],
          %{Accentone.role() => pos_integer()},
          :error | :drop
        ) :: {:ok, result()} | {:error, Accentone.error_reason()}
  def parse(%{finish_reason: finish_reason} = result, colors, counts, on_invalid_color) do
    with :ok <- check_finish_reason(finish_reason),
         {:ok, object} <- decode_payload(result) do
      build_result(object, colors, counts, on_invalid_color)
    end
  end

  # -- step 1: finish_reason -----------------------------------------------

  # Only `:length` is truncation today, and `ReqLLM` normalizes it — including
  # the providers that spell it `max_tokens` or `max_output_tokens`. The clause
  # is shaped so a future reason can be carried without changing arity; `:stop`,
  # `:content_filter`, and `nil` all proceed to the content.
  defp check_finish_reason(:length), do: {:error, {:truncated, :length}}
  defp check_finish_reason(_other), do: :ok

  # -- step 2, then step 3: the object, else the decoder --------------------

  # A recovered object is the entire answer, and nothing about the text matters
  # once there is one.
  defp decode_payload(%{object: %{} = object}), do: {:ok, object}

  defp decode_payload(%{content: content}) do
    with {:ok, text} <- content_text(content) do
      decode_object(text)
    end
  end

  defp decode_payload(_other), do: content_text(nil)

  # -- step 3: content ------------------------------------------------------

  # `content` may be a string, a parts list, or `null`; refusal prose is
  # deliberately not carried in an error term. A tool-call or `refusal` reply
  # arrives as `null`.
  defp content_text(content) when is_binary(content), do: {:ok, content}

  defp content_text(parts) when is_list(parts), do: {:ok, join_text_parts(parts)}

  defp content_text(nil), do: {:error, {:invalid_response, {:content, :null}}}

  defp content_text(_other), do: {:error, {:invalid_response, {:content, :not_a_string}}}

  # Join the `text` of the `type: "text"` parts, in order, ignoring every part
  # that is not a map, is not a text part, or whose `text` is not a string. A
  # list with no text part therefore joins to `""`, which falls through to
  # `{:invalid_json, :no_object}` exactly like empty prose.
  defp join_text_parts(parts) do
    parts
    |> Enum.filter(&text_part?/1)
    |> Enum.map_join("", & &1["text"])
  end

  defp text_part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp text_part?(_part), do: false

  # -- step 3, continued: fences and decode ---------------------------------

  defp decode_object(text) do
    stripped = strip_fences(text)

    case Jason.decode(stripped) do
      {:ok, %{} = object} ->
        {:ok, object}

      # A decoded value that is not an object (array, string, number, boolean,
      # `null`) is the same member as a non-object envelope: the model ignored
      # the "JSON object only" instruction.
      {:ok, _other} ->
        {:error, {:invalid_response, :not_an_object}}

      {:error, _reason} ->
        decode_extracted(stripped)
    end
  end

  defp decode_extracted(stripped) do
    case extract_object(stripped) do
      {:ok, candidate} ->
        case Jason.decode(candidate) do
          {:ok, %{} = object} -> {:ok, object}
          {:ok, _other} -> {:error, {:invalid_response, :not_an_object}}
          {:error, _reason} -> {:error, {:invalid_json, :malformed}}
        end

      # Empty content or pure prose: there is no object to be malformed.
      :error ->
        {:error, {:invalid_json, :no_object}}
    end
  end

  # The prompt forbids fences, but honouring them costs nothing. A fence that is
  # not the whole content (leading prose) still works, because the extractor in
  # step 6 finds the `{...}` regardless of the surrounding backticks.
  defp strip_fences(text) do
    trimmed = String.trim(text)

    case Regex.run(@fence, trimmed, capture: :all_but_first) do
      [body] -> String.trim(body)
      nil -> trimmed
    end
  end

  # The outermost balanced `{...}`, in one left-to-right pass.
  #
  # "Outermost" is the **leftmost** `{` that closes at all — the same answer as
  # trying every `{` in turn, which is what this used to do: a stray unbalanced
  # brace in the prose cannot hide a later real object, because the stray never
  # closes and the real one does. Matching is a brace stack (a `}` closes the
  # nearest unmatched `{`) and the candidate is the smallest start among the
  # closes, so the pass is linear instead of rescanning the tail once per `{`.
  #
  # The scanner is byte-oriented and string/escape-aware, so `{"hex":"#A}B"}` and
  # `{"note":"a\"}b"}` neither truncate nor unbalance it.
  defp extract_object(text) do
    case scan_object(text, 0, [], nil, false, false) do
      {start, stop} -> {:ok, binary_part(text, start, stop - start + 1)}
      nil -> :error
    end
  end

  # Past the end of the input: whatever the pass found, or nothing at all.
  defp scan_object(text, index, _stack, best, _in_string, _escape)
       when index >= byte_size(text),
       do: best

  # Inside a JSON string a brace is a byte like any other: `\\` escapes and the
  # next byte is literal, and a `"` ends the string.
  defp scan_object(text, index, stack, best, true, true) do
    scan_object(text, index + 1, stack, best, true, false)
  end

  defp scan_object(text, index, stack, best, true, false) do
    case :binary.at(text, index) do
      ?\\ -> scan_object(text, index + 1, stack, best, true, true)
      ?" -> scan_object(text, index + 1, stack, best, false, false)
      _byte -> scan_object(text, index + 1, stack, best, true, false)
    end
  end

  # Outside a string, `{` opens and `}` closes the nearest open one; a `}` with
  # nothing open is prose. An inner close pops first and an outer, smaller start
  # may follow, so the candidate is the leftmost start seen, not the first pop.
  defp scan_object(text, index, stack, best, false, _escape) do
    case :binary.at(text, index) do
      ?" ->
        scan_object(text, index + 1, stack, best, true, false)

      ?{ ->
        scan_object(text, index + 1, [index | stack], best, false, false)

      ?} ->
        case stack do
          [] ->
            scan_object(text, index + 1, [], best, false, false)

          [start | rest] ->
            scan_object(text, index + 1, rest, closer(best, start, index), false, false)
        end

      _byte ->
        scan_object(text, index + 1, stack, best, false, false)
    end
  end

  defp closer(nil, start, stop), do: {start, stop}
  defp closer({best_start, _} = best, start, _stop) when start >= best_start, do: best
  defp closer(_best, start, stop), do: {start, stop}

  # -- steps 4 & 5: roles, entries, and normalization -----------------------

  defp build_result(object, colors, counts, on_invalid_color) do
    case collect_fields(object, colors, counts, on_invalid_color) do
      {:ok, fields, dropped_by_field} -> palette_result(fields, dropped_by_field)
      {:error, reason} -> {:error, reason}
    end
  end

  # Step 5: only a wholly empty palette is an error — short and empty lists
  # are legitimate answers the prompt explicitly licenses.
  defp palette_result(fields, dropped_by_field) do
    if Enum.all?(fields, fn {_field, list} -> list == [] end) do
      {:error, {:invalid_response, :no_colors}}
    else
      {:ok,
       %{
         fields: fields,
         dropped: dropped_by_field |> Map.values() |> Enum.sum(),
         dropped_by_field: dropped_by_field
       }}
    end
  end

  defp collect_fields(object, colors, counts, on_invalid_color) do
    Enum.reduce_while(colors, {:ok, %{}, %{}}, fn role, acc ->
      collect_field(object, role, counts, on_invalid_color, acc)
    end)
  end

  defp collect_field(object, role, counts, on_invalid_color, {:ok, fields, dropped}) do
    field = Prompt.field(role)

    case Map.get(object, Atom.to_string(field)) do
      entries when is_list(entries) ->
        collect_entries(
          entries,
          field,
          Map.fetch!(counts, role),
          on_invalid_color,
          fields,
          dropped
        )

      # Step 4: a missing key and an explicit `null` are the same answer —
      # several OpenAI-compatible servers emit `null` for an empty array.
      # Unrequested roles are never read, so a volunteered key is ignored.
      nil ->
        {:cont, {:ok, Map.put(fields, field, []), dropped}}

      _other ->
        {:halt, {:error, {:invalid_response, {field, :not_a_list}}}}
    end
  end

  defp collect_entries(entries, field, count, on_invalid_color, fields, dropped) do
    case normalize_entries(entries, field, count, on_invalid_color) do
      {:ok, list, dropped_count} ->
        dropped = put_dropped(dropped, field, dropped_count)
        {:cont, {:ok, Map.put(fields, field, list), dropped}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp put_dropped(dropped, _field, 0), do: dropped
  defp put_dropped(dropped, field, count), do: Map.put(dropped, field, count)

  defp normalize_entries(entries, field, count, on_invalid_color) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {entry, index}, acc ->
      normalize_indexed_entry(entry, field, index, on_invalid_color, acc)
    end)
    |> finalize_entries(count)
  end

  defp normalize_indexed_entry(entry, field, index, on_invalid_color, {:ok, acc, dropped}) do
    case normalize_entry(entry, field, index) do
      {:ok, color} ->
        {:cont, {:ok, [color | acc], dropped}}

      {:error, reason} ->
        drop_or_halt(reason, on_invalid_color, acc, dropped)
    end
  end

  # `:drop` is entry-level only. `normalize_entry/3` reports only
  # entry-level failures, so every error reaching here is eligible to be
  # dropped instead of failing the call; role- and payload-level shapes never
  # get this far.
  defp drop_or_halt(_reason, :drop, acc, dropped), do: {:cont, {:ok, acc, dropped + 1}}
  defp drop_or_halt(reason, _mode, _acc, _dropped), do: {:halt, {:error, reason}}

  defp finalize_entries({:ok, acc, dropped}, count) do
    list =
      acc
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.hex)
      |> Enum.take(count)

    {:ok, list, dropped}
  end

  defp finalize_entries({:error, reason}, _count), do: {:error, reason}

  defp normalize_entry(%{} = entry, field, index) do
    case Map.fetch(entry, @hex_field) do
      {:ok, raw} ->
        case normalize_hex(raw) do
          {:ok, hex} ->
            {:ok, %Color{hex: hex, confidence: confidence(Map.get(entry, "confidence"))}}

          :error ->
            {:error, {:invalid_color, {field, index}, raw}}
        end

      # A missing `hex` is its own member — the caller sees that the entry
      # was shaped right but incomplete, distinct from a bad value.
      :error ->
        {:error, {:missing_field, {field, index}, @hex_field}}
    end
  end

  defp normalize_entry(_entry, field, index),
    do: {:error, {:invalid_response, {field, index, :not_an_object}}}

  # Trim, drops exactly one leading `#`, trim again, then require six hex digits.
  # 3-digit shorthand, 8-digit alpha, names, and non-strings are all rejected —
  # silently expanding them would hide a model drifting off-spec.
  defp normalize_hex(raw) when is_binary(raw) do
    hex =
      raw
      |> String.trim()
      |> String.replace_prefix("#", "")
      |> String.trim()
      |> String.upcase()

    if Regex.match?(@hex, hex), do: {:ok, "#" <> hex}, else: :error
  end

  defp normalize_hex(_raw), do: :error

  # Advisory, so it degrades to `nil` rather than failing: numbers and numeric
  # strings are coerced to floats and clamped to `0.0..1.0`, and everything else
  # (`true`, `"high"`, a map) is `nil`. `"0.8x"` is not a number.
  defp confidence(nil), do: nil
  defp confidence(value) when is_integer(value), do: value |> Kernel.*(1.0) |> clamp()
  defp confidence(value) when is_float(value), do: clamp(value)

  defp confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> clamp(number)
      _other -> nil
    end
  end

  defp confidence(_other), do: nil

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
