defmodule Accentone.Schema do
  @moduledoc false

  # The JSON Schema handed to the provider, built per request from the resolved
  # `:colors` and `:counts`.
  #
  # It is a **raw JSON Schema map** rather than a keyword list or a `Zoi` type
  # because `ReqLLM.Schema.compile/1` passes a plain map through unchanged: what
  # is written here is literally the document the provider receives, so a test
  # asserts a path in it without knowing a schema DSL.
  #
  # Two deliberate omissions, and both are the point rather than an oversight:
  #
  #   * There is no `"required"`. A role the provider leaves out has to stay `[]`
  #     — the documented "asked and empty" answer — rather than becoming a
  #     provider-side validation failure that reads as "the image had no such
  #     color". `Accentone.Parser` remains the authority on what a color is
  #     (doc 10's D3 and F3), and it already treats an absent role as `[]`.
  #   * There is no `"additionalProperties": false`, for the same reason: this
  #     shapes a reply, it does not police one.
  #
  # The `hex` pattern and the `confidence` range are duplicated from
  # `Accentone.Color` and `Accentone.Parser` on purpose. The duplication is the
  # design: the schema tells the provider what to produce, the parser decides
  # what it got, and neither is derived from the other.

  alias Accentone.Prompt

  @hex "^#[0-9A-Fa-f]{6}$"

  @doc """
  One `<role>_colors` array per requested role, capped at that role's own count.
  """
  @spec build([Accentone.role()], %{Accentone.role() => pos_integer()}) :: map()
  def build(colors, counts) do
    %{
      "type" => "object",
      "properties" => Map.new(colors, fn role -> {field(role), list(counts[role])} end)
    }
  end

  defp field(role), do: role |> Prompt.field() |> Atom.to_string()

  defp list(count) do
    %{
      "type" => "array",
      "maxItems" => count,
      "items" => %{
        "type" => "object",
        "properties" => %{
          "hex" => %{"type" => "string", "pattern" => @hex},
          "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
        }
      }
    }
  end
end
