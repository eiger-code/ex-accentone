defmodule Accentone.Prompt do
  @moduledoc false

  require EEx

  # The canonical role vocabulary and the role ↔ field mapping (the six-row
  # table) live here, in one place, because `Config` validates `:colors`
  # against `roles/0`, `Palette.get/2` and `Parser` resolve fields through
  # `field/1`, and the prompt builder below owns the per-role descriptions.
  # Copying the six-row table into those modules is exactly the divergence this
  # shared definition prevents. The public `role()` type is the one piece that cannot live
  # here: this module is `@moduledoc false`, so the type union is defined on
  # `Accentone` and referenced from every spec (a hidden module cannot be linked
  # from the published docs).

  @roles [:key, :accent, :background, :surface, :muted, :highlight]

  @fields %{
    key: :key_colors,
    accent: :accent_colors,
    background: :background_colors,
    surface: :surface_colors,
    muted: :muted_colors,
    highlight: :highlight_colors
  }

  # The prompt's *wording* is what matters, not its line wrapping. Code blocks
  # are wrapped at ~80 columns for readability, and a per-role `count:` that
  # varies by request cannot be hard-wrapped deterministically anyway. Every
  # template paragraph is therefore one line — and so is every rubric bullet —
  # while the wording stays verbatim. Markdown emphasis from the
  # role-description prose (`*coverage*`, `` `accent_colors` ``) is stripped for
  # the same reason: it is document formatting, not prompt content.
  #
  # Concrete example entries exist for `key_colors` and `accent_colors` only,
  # because the canonical block is the two-role default. The other four roles are
  # filled here with role-appropriate `#RRGGBB` pairs; only the example's shape
  # and format matter to the model, not its colour.

  @examples %{
    key: {"3A6EA5", "0.87"},
    accent: {"FFB000", "0.72"},
    background: {"1C1B19", "0.90"},
    surface: {"E9E4DA", "0.76"},
    muted: {"8A93A0", "0.64"},
    highlight: {"F7F4EC", "0.82"}
  }

  # -- prompt wording lives in `prompt/*.eex` -------------------------------
  #
  # Everything the model reads is a template: the two prompt layouts, the six
  # per-role description blocks, and the JSON-only sentence appended to every
  # prompt.
  # This module keeps the vocabulary, the field mapping, the example values, and
  # the render logic — no prompt prose — so the wording has exactly one home to
  # review.
  #
  # The layouts are compiled into functions, so nothing is parsed at request
  # time. The fragments are rendered into attributes at compile time instead,
  # because a description is chosen by role at runtime and re-rendering a
  # constant per request would be work for nothing. `@external_resource` is
  # registered for every template — `function_from_file/5` does that itself, the
  # fragments need it spelled out — so editing one recompiles this module.
  #
  # `trim: false` (EEx's default) is deliberate: prompt newlines are content.
  # Trimming drops whitespace-only lines next to a tag, which would silently
  # collapse a blank line that means `"\n\n"` down to `"\n"`. Two things follow,
  # and both are load-bearing when reading the layouts:
  #
  #   * a loop body carries its own trailing blank line, which is what separates
  #     two role sections, and the JSON example from the prose after it, and
  #   * the `<% end %>` of those loops therefore abuts the next paragraph on the
  #     same line — putting it on a line of its own would add a newline.
  #
  # A template file's own final newline is a file artifact rather than prompt
  # content, so every render is `String.trim_trailing/1`-ed on the way out.
  #
  # The role fragments are split so that the rule — `:terse` is the default
  # prompt with the rubric and the scoring bands removed — is structural rather
  # than copied: `roles/key.eex` is the sentence both prompts share, and
  # `roles/key_rubric.eex` is the part only `:default` appends.

  @prompt_dir Path.expand("prompt", __DIR__)

  @template_files Enum.map(@roles, fn role -> "roles/#{role}.eex" end) ++
                    ["default.eex", "terse.eex", "json_instruction.eex", "roles/key_rubric.eex"]

  for file <- @template_files, do: @external_resource(Path.join(@prompt_dir, file))

  # The six description blocks as the fragment files hold them: `:key` is the
  # terse wording, so this is the set `:terse` renders, and `@descriptions` below
  # adds the rubric back for `:default`.
  @terse_descriptions (for role <- @roles, into: %{} do
                         path = Path.join(@prompt_dir, "roles/#{role}.eex")
                         {role, path |> EEx.eval_file() |> String.trim_trailing()}
                       end)

  @key_rubric Path.join(@prompt_dir, "roles/key_rubric.eex")
              |> EEx.eval_file()
              |> String.trim_trailing()

  @descriptions Map.update!(@terse_descriptions, :key, &(&1 <> " " <> @key_rubric))

  @json_instruction Path.join(@prompt_dir, "json_instruction.eex")
                    |> EEx.eval_file()
                    |> String.trim_trailing()

  EEx.function_from_file(:defp, :render_default, Path.join(@prompt_dir, "default.eex"), [
    :examples,
    :sections
  ])

  EEx.function_from_file(:defp, :render_terse, Path.join(@prompt_dir, "terse.eex"), [:sections])

  @doc """
  The six built-in roles, in canonical order.

  This is the vocabulary's order, not a request's order: `colors:` may name any
  subset in any order, and `Palette.roles/1` preserves *that* order.
  """
  @spec roles() :: [Accentone.role()]
  def roles, do: @roles

  @doc """
  The `Accentone.Palette` field name for `role` — `:key → :key_colors`.

  Raises `ArgumentError` outside the six built-in roles: an unknown role is a
  bug, and it must not silently answer like an unrequested one.
  """
  @spec field(Accentone.role()) :: atom()
  def field(role) do
    case Map.fetch(@fields, role) do
      {:ok, field} -> field
      :error -> raise ArgumentError, "unknown color role: #{inspect(role)}"
    end
  end

  @doc """
  Build the request prompt for `kind` and the requested `colors`.

  `kind` is `:default`, `:terse`, or a caller-supplied binary, and `counts` maps
  each requested role to its resolved limit. `:default` generates the default
  prompt from the request — one key and one example entry per role, in the
  caller's `colors` order, with each role's own count on its own line — and
  `:terse` renders the shorter template. A binary is used exactly as supplied.

  Structured output is the only output, so the JSON-only instruction rides on the
  library's own two templates — `:default` and `:terse` — and on nothing else.
  A caller-supplied binary is used exactly as supplied, and every requested role's
  field name must appear in the resolved prompt as a whole, case-sensitive token —
  `key_colors` passes while `Key_Colors`, `key_colors_extra`, and
  `not_key_colors` fail — or the result is
  `{:error, {:invalid_option, :prompt, {:missing_role_key, field}}}` before any
  I/O.
  """
  @spec build(
          :default | :terse | binary(),
          [Accentone.role()],
          %{Accentone.role() => pos_integer()}
        ) ::
          {:ok, binary()} | {:error, Accentone.error_reason()}
  def build(kind, colors, counts) do
    with {:ok, prompt} <- render(kind, colors, counts) do
      require_role_keys(prompt, colors)
    end
  end

  # The instruction belongs to the library's prose, never to the caller's:
  # `:prompt`'s contract is that a binary is used exactly as supplied. Both
  # templates say "json" already, so `append_json_instruction/1`'s guard is what
  # makes this a no-op — and what keeps a future template edit from collecting
  # the sentence twice.
  defp render(:default, colors, counts) do
    {:ok, default_prompt(colors, counts) |> append_json_instruction()}
  end

  defp render(:terse, colors, counts) do
    {:ok, terse_prompt(colors, counts) |> append_json_instruction()}
  end

  defp render(custom, _colors, _counts) when is_binary(custom), do: {:ok, custom}
  defp render(other, _colors, _counts), do: {:error, {:invalid_option, :prompt, other}}

  # -- :default -------------------------------------------------------------

  defp default_prompt(colors, counts) do
    render_default(example_entries(colors), role_sections(colors, counts, @descriptions))
    |> String.trim_trailing()
  end

  # -- :terse ---------------------------------------------------------------

  # The terse template states the shape once, so the per-role counts ride on the
  # role lines exactly as in `:default` — the one place they can differ per role.
  defp terse_prompt(colors, counts) do
    render_terse(role_sections(colors, counts, @terse_descriptions))
    |> String.trim_trailing()
  end

  # The `{field, count, description}` triples the layouts interpolate, one per
  # requested role in the caller's order. The limit rides on the role's own line,
  # so a non-uniform `count:` needs no separate sentence and no role can inherit
  # another's number. Only the description set differs between the prompts.
  defp role_sections(colors, counts, descriptions) do
    Enum.map(colors, fn role ->
      {field(role), Map.fetch!(counts, role), Map.fetch!(descriptions, role)}
    end)
  end

  # The `{field, hex, confidence}` example entries for the default layout's JSON
  # block, one per requested role.
  defp example_entries(colors) do
    Enum.map(colors, fn role ->
      {hex, confidence} = Map.fetch!(@examples, role)
      {field(role), hex, confidence}
    end)
  end

  # -- the JSON-only instruction -------------------------------------------

  # Applied to the library's two templates and to nothing else. Unconditional now
  # that structured output is the only output, and still guarded: a template that
  # already says "json" gets no second sentence telling it the same thing.
  defp append_json_instruction(prompt) do
    if Regex.match?(~r/\bjson\b/i, prompt) do
      prompt
    else
      prompt <> "\n\n" <> @json_instruction
    end
  end

  # -- the pre-flight role-key check ---------------------------------------

  defp require_role_keys(prompt, colors) do
    Enum.find_value(colors, {:ok, prompt}, fn role ->
      field = field(role)

      unless Regex.match?(Regex.compile!("\\b#{field}\\b"), prompt) do
        {:error, {:invalid_option, :prompt, {:missing_role_key, field}}}
      end
    end)
  end
end
