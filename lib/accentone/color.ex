defmodule Accentone.Color do
  @moduledoc """
  A single extracted color.

  The library builds these from a validated model response, so a `%Color{}` that
  came out of `Accentone.analyze/2` has an uppercase `#RRGGBB` `hex` and a
  `confidence` that is a float in `0.0..1.0` or `nil`:

      %Accentone.Color{hex: "#3A6EA5", confidence: 0.87}

  The fields are ordinary Elixir terms, so a caller can write
  `%Accentone.Color{hex: "nope"}` by hand; the guarantee is about the library's
  output, not about the type being unforgeable. `valid?/1` is for those
  hand-built values — fixtures and expected values in your own tests — so a typo
  surfaces as a failed assertion on the value instead of as a diff against a
  struct the library would never produce. It reports, and never repairs: it is
  not a constructor.
  """

  defstruct [:hex, :confidence]

  @type t :: %__MODULE__{
          hex: String.t(),
          confidence: float() | nil
        }

  # `\A`/`\z` rather than `^`/`$`: `$` also matches before a trailing newline,
  # and `"#3A6EA5\n"` must not validate.
  @hex ~r/\A#[0-9A-F]{6}\z/

  @doc """
  Whether `color` is a valid extracted color: `hex` is uppercase `#RRGGBB`, and
  `confidence` is a float in `0.0..1.0` or `nil`.

  Everything else is rejected — `"#ABC"`, 8-digit hex, `"steel blue"`, a missing
  or non-string hex, an integer confidence (the parser coerces numbers to floats,
  `valid?/1` does not), an out-of-range or non-numeric confidence, and any value
  that is not a `%Accentone.Color{}` at all.

      iex> Accentone.Color.valid?(%Accentone.Color{hex: "#3A6EA5", confidence: 0.87})
      true

      iex> Accentone.Color.valid?(%Accentone.Color{hex: "#abc", confidence: nil})
      false
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{hex: hex, confidence: confidence}) do
    is_binary(hex) and Regex.match?(@hex, hex) and valid_confidence?(confidence)
  end

  def valid?(_not_a_color), do: false

  defp valid_confidence?(nil), do: true

  defp valid_confidence?(confidence) when is_float(confidence) do
    confidence >= 0.0 and confidence <= 1.0
  end

  defp valid_confidence?(_other), do: false
end
