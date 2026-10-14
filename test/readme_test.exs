defmodule Accentone.ReadmeTest do
  use ExUnit.Case, async: true

  alias Accentone.Color
  alias Accentone.Config
  alias Accentone.Fixtures
  alias Accentone.Palette
  alias Accentone.Stub

  # README.md is the HexDocs front page (`main: "readme"`), so its examples and
  # its option table are published surface that happens to live outside
  # `@moduledoc`. Nothing else in the suite reads it and `mix docs` does not
  # execute it, so this module is where the README is checked against the code
  # rather than against a previous draft of itself:
  #
  #   * every ```elixir block parses;
  #   * every `# =>` expectation in the Quickstart is what `analyze/2` actually
  #     returns, through the same `Req.Test` seam the rest of the suite uses;
  #   * the option table covers `Accentone.Config`'s own enumerations — every
  #     option, every env var name, every scalar default — so an option added
  #     without a documented row fails here, and a documented row for an option
  #     that no longer exists fails too;
  #   * every `#anchor` link resolves to a heading, at any depth — the options
  #     section links into an `####` sub-heading, so the anchors harvested here
  #     have to go deeper than the `##`/`###` pair a table of contents uses.
  #
  # The Contents list used to be a fourth check here, asserting that every heading
  # was named in it. README.md opens with a five-link jump bar instead, so that
  # check has no subject: it is removed rather than loosened, because an extractor
  # that finds links anywhere in the file would pass while asserting nothing.
  #
  # The error taxonomy used to be a second table here. It lives in
  # `Accentone.Error`'s `@moduledoc` now — README.md only links to it — so that
  # check moved to `error_test.exs`, beside the `message/1` clauses that render
  # the same taxonomy.

  @readme Path.expand("../README.md", __DIR__)

  @option_header "| option | env var | default |"
  @no_env "—"

  # README.md carries nine ```elixir blocks since `Reading a palette` was removed,
  # which is the floor here rather than a target: it exists so an extraction that
  # returns nothing cannot pass the parse check vacuously, and lowering it is what
  # a trim of the examples is allowed to do.
  test "every elixir block parses" do
    blocks = elixir_blocks(readme())
    assert length(blocks) >= 9

    for block <- blocks do
      assert {:ok, _ast} = Code.string_to_quoted(block), "block does not parse:\n#{block}"
    end
  end

  test "the Quickstart's documented output is what analyze/2 returns" do
    path = write_fixture!()
    source = quickstart_source(readme())

    # A Responses-API envelope, because the Quickstart calls `analyze/2` with no
    # `:model` and the default spec (`"openai:gpt-4o"`) routes to `/v1/responses`.
    # A chat-shaped body there decodes to an empty message rather than failing.
    Stub.install(fn conn ->
      Req.Test.json(
        conn,
        Stub.responses_body([{:key, "#3A6EA5", 0.87}, {:accent, "#FFB000", 0.72}])
      )
    end)

    {bindings, checked} = eval_documented(source, path: path)

    # The block's own `# =>` comments are the assertion — not a copy of them —
    # so both of them have to have been reached for this test to mean anything.
    documented = Enum.filter(checked, fn {_statement, _value, expected} -> expected end)

    assert length(documented) == 2
    assert Enum.all?(documented, fn {_s, value, _e} -> match?([%Color{} | _], value) end)
    assert is_struct(bindings[:palette], Palette)
  end

  test "the option table covers Config's options, env vars, and scalar defaults" do
    documented =
      readme()
      |> table_rows(@option_header)
      |> Map.new(fn {option, env, default} -> {option, {env, default}} end)

    assert Enum.sort(Map.keys(documented)) == Enum.sort(Config.known_options())

    env_names = Map.new(Config.env_vars(), fn {var, name} -> {name, var} end)
    defaults = Config.scalar_defaults()

    for option <- Config.known_options() do
      {env_cell, default_cell} = Map.fetch!(documented, option)

      case Map.fetch(env_names, option) do
        {:ok, var} ->
          assert env_cell == var,
                 "#{inspect(option)} is read from #{var}; the table says #{inspect(env_cell)}"

        :error ->
          assert env_cell == @no_env,
                 "#{inspect(option)} has no env var, so its cell must be #{@no_env}"
      end

      case Map.fetch(defaults, option) do
        {:ok, default} ->
          # `inspect/1` never adds digit separators, but the table writes
          # `10_000_000`, so the cell is compared with them removed.
          assert String.contains?(String.replace(default_cell, "_", ""), inspect(default)),
                 "#{inspect(option)} defaults to #{inspect(default)}, which is not in " <>
                   "the row: #{inspect(default_cell)}"

        :error ->
          :ok
      end
    end
  end

  test "every internal link resolves to a heading" do
    markdown = readme()
    headings = heading_anchors(markdown)
    links = Regex.scan(~r/\]\(#([0-9a-z-]+)\)/, markdown) |> Enum.map(&List.last/1)

    assert links != []

    for link <- links do
      assert link in headings, "no heading anchors to ##{link}"
    end
  end

  # -- the README, read as data ---------------------------------------------

  defp readme, do: File.read!(@readme)

  defp elixir_blocks(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce({[], :outside}, fn
      "```elixir", {blocks, :outside} -> {blocks, {:inside, []}}
      "```", {blocks, {:inside, lines}} -> {[joined(lines) | blocks], :outside}
      line, {blocks, {:inside, lines}} -> {blocks, {:inside, [line | lines]}}
      _line, {blocks, :outside} -> {blocks, :outside}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp joined(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  defp table_lines(markdown, header) do
    lines = String.split(markdown, "\n")

    case Enum.find_index(lines, &(&1 == header)) do
      nil -> flunk("no table headed #{inspect(header)}")
      start -> lines |> Enum.drop(start) |> Enum.take_while(&String.starts_with?(&1, "|"))
    end
  end

  defp table_rows(markdown, header) do
    markdown
    |> table_lines(header)
    |> Enum.drop(2)
    |> Enum.map(fn row ->
      [_leading, option, env, default, _trailing] = String.split(row, "|")

      {option_name(option), cell(env), cell(default)}
    end)
  end

  defp option_name(cell) do
    cell |> cell() |> String.trim_leading(":") |> String.to_atom()
  end

  defp cell(text), do: text |> String.trim() |> String.trim("`")

  defp heading_anchors(markdown) do
    markdown
    |> String.split("\n")
    # `##` through `####`: the deepest heading README.md links to is `#### Where
    # an option comes from`, and a narrower filter reports that link as broken.
    |> Enum.filter(&Regex.match?(~r/^\#{2,4} /, &1))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\#+ /, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9 -]/, "")
      |> String.replace(" ", "-")
    end)
  end

  # -- the Quickstart, executed ---------------------------------------------

  defp quickstart_source(markdown) do
    block =
      markdown
      |> elixir_blocks()
      |> Enum.find(&String.contains?(&1, ~s|{:ok, palette} = Accentone.analyze("photo.jpg")|))

    if block do
      # The documented call stays a path; only the file and the transport are
      # substituted, so the block is still the README's own text.
      String.replace(
        block,
        ~s|Accentone.analyze("photo.jpg")|,
        ~s|Accentone.analyze(path, reqllm_options: [req_http_options: [plug: Accentone.Stub.plug()]])|
      )
    else
      flunk("no Quickstart block found — it no longer calls Accentone.analyze(\"photo.jpg\")")
    end
  end

  # Evaluate the block's blank-line-separated chunks in order, asserting that a
  # chunk's `# => …` comment is what the chunk actually evaluates to.
  defp eval_documented(source, bindings) do
    Enum.reduce(expectations(source), {bindings, []}, fn {statement, expected},
                                                         {bindings, checked} ->
      {value, bindings} = Code.eval_string(statement, bindings)

      if expected do
        assert inspect(value) == expected,
               "#{statement}\n# => #{expected}\nbut evaluated to #{inspect(value)}"
      end

      {bindings, checked ++ [{statement, value, expected}]}
    end)
  end

  defp expectations(source) do
    source
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&chunk_expectation/1)
  end

  defp chunk_expectation(chunk) do
    lines = String.split(chunk, "\n")

    case Enum.find_index(lines, &String.starts_with?(&1, "# =>")) do
      nil ->
        {chunk, nil}

      index ->
        statement = lines |> Enum.take(index) |> Enum.join("\n") |> String.trim()
        expected = lines |> Enum.drop(index) |> Enum.map(&String.trim_leading(&1, "# => "))

        {statement, Enum.join(expected, "\n")}
    end
  end

  defp write_fixture! do
    path =
      Path.join(System.tmp_dir!(), "accentone-readme-#{System.unique_integer([:positive])}.png")

    File.write!(path, Fixtures.png())
    on_exit(fn -> File.rm(path) end)
    path
  end
end
