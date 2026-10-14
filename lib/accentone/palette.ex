defmodule Accentone.Palette do
  @moduledoc """
  The result of a successful `Accentone.analyze/2` call: one list of
  `Accentone.Color` per built-in role, plus the roles that were requested.

      {:ok, %Accentone.Palette{
        roles: [:key, :accent],
        key_colors: [%Accentone.Color{hex: "#3A6EA5", confidence: 0.87}],
        accent_colors: [%Accentone.Color{hex: "#FFB000", confidence: 0.72}],
        background_colors: nil,
        surface_colors: nil,
        muted_colors: nil,
        highlight_colors: nil
      }}

  ## `nil` versus `[]`

  An **unrequested** role is `nil`; a **requested** role the model found nothing
  for is `[]`. That distinction is deliberate — "you didn't ask" must not look
  like "asked and the image had no such color". `roles/1` is how a caller
  recovers which roles were asked for, and in what order.

  ## Ordering and length

  Each list holds **at most that role's `count`** entries, ordered most important
  first. Position 1 is the primary answer for that role; positions 2+ are ordered
  hints and their `confidence` may be `nil`. Exact duplicate hex values are
  collapsed within a list, keeping the first occurrence; dedup does not cross
  roles.
  """

  alias Accentone.Color
  alias Accentone.Prompt

  defstruct roles: [],
            key_colors: nil,
            accent_colors: nil,
            background_colors: nil,
            surface_colors: nil,
            muted_colors: nil,
            highlight_colors: nil

  @type t :: %__MODULE__{
          roles: [Accentone.role()],
          key_colors: [Color.t()] | nil,
          accent_colors: [Color.t()] | nil,
          background_colors: [Color.t()] | nil,
          surface_colors: [Color.t()] | nil,
          muted_colors: [Color.t()] | nil,
          highlight_colors: [Color.t()] | nil
        }

  @doc """
  The colors `palette` holds for `role`, most important first.

  Returns `[]` when the role was not requested, so generic iteration is total:

      for role <- Accentone.Palette.roles(palette),
          color <- Accentone.Palette.get(palette, role) do
        color.hex
      end

  Raises `ArgumentError` for an atom outside the six built-in roles. An
  unrequested role is a caller decision and deserves the quiet answer; a
  misspelled role is a bug, and it must not look like an empty palette. Read
  the raw field (or `roles/1`) if you need to tell `nil` from `[]`.

      iex> Accentone.Palette.get(%Accentone.Palette{roles: [:key]}, :background)
      []

      iex> Accentone.Palette.get(%Accentone.Palette{roles: [:key], key_colors: []}, :key)
      []
  """
  @spec get(t(), Accentone.role()) :: [Color.t()]
  def get(%__MODULE__{} = palette, role) do
    case Map.fetch!(palette, Prompt.field(role)) do
      nil -> []
      colors -> colors
    end
  end

  @doc """
  The roles that were requested, in the caller's `colors:` order.

  Always a list, never `nil`. The default call yields `[:key, :accent]`. This is
  also the order the prompt asked for them in and the order telemetry reports,
  so a caller can correlate all three.

      iex> Accentone.Palette.roles(%Accentone.Palette{roles: [:accent, :key]})
      [:accent, :key]
  """
  @spec roles(t()) :: [Accentone.role()]
  def roles(%__MODULE__{roles: roles}), do: roles
end
