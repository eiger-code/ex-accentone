defmodule Accentone.Stub do
  @moduledoc false

  # The test seam: the stub is injected through `:reqllm_options`'s
  # `:req_http_options`, which `ReqLLM` splices straight into `Req.new/1` — the
  # same Req option a caller would use — so the payload tests and the "callers can
  # fully override transport" test are the same test.
  #
  # Attempts are counted with `:counters/1` rather than the process dictionary
  # because the recommended caller shape runs `analyze/2` in a spawned `Task`:
  # with `Req.Test.allow/3` the handler runs in that task, so a per-process
  # counter would miss attempts.

  import ExUnit.Assertions, only: [assert: 2]

  @name __MODULE__

  @default_usage %{
    "prompt_tokens" => 380,
    "completion_tokens" => 130,
    "total_tokens" => 510
  }

  # The Responses API reports the normalized names directly.
  @default_responses_usage %{
    "input_tokens" => 380,
    "output_tokens" => 130,
    "total_tokens" => 510
  }

  @doc "The `:plug` value for a raw `Req.request!/1` in the harness's own tests."
  def plug, do: {Req.Test, @name}

  @doc """
  The `:reqllm_options` value that routes a resolved config at this stub.

  `:req_http_options` is `ReqLLM`'s passthrough to Req, so this is the seam a
  caller would use to point the library at a proxy — which is why the payload
  rows and the transport-override row are the same test.
  """
  def http_options, do: [req_http_options: [plug: plug()]]

  @doc """
  Installs `handler` as this test's stub and returns the attempt counter.

  `handler` is a `(Plug.Conn.t() -> Plug.Conn.t())`. Pass the returned counter
  to `attempts/1`, or to `verify_no_call!/1` for the zero-call guarantee.
  """
  @spec install((Plug.Conn.t() -> Plug.Conn.t())) :: reference()
  def install(handler) when is_function(handler, 1) do
    install_attempts(fn conn, _attempt -> handler.(conn) end)
  end

  @doc """
  Installs an attempt-aware stub and returns the attempt counter.

  `handler` is `(Plug.Conn.t(), pos_integer() -> Plug.Conn.t())` and receives
  the 1-based attempt number, which is what the retry rows need to answer `429`
  once and `200` after — `Req` re-runs the adapter per attempt, so the same
  stub sees each one.
  """
  @spec install_attempts((Plug.Conn.t(), pos_integer() -> Plug.Conn.t())) :: reference()
  def install_attempts(handler) when is_function(handler, 2) do
    counter = :counters.new(1, [])

    Req.Test.stub(@name, fn conn ->
      # `:counters.add/3` returns `:ok`, not the new value — read it back.
      :counters.add(counter, 1, 1)
      handler.(conn, :counters.get(counter, 1))
    end)

    counter
  end

  @doc "How many requests the stub saw — the wire-side `attempts` of the retry rows."
  def attempts(counter), do: :counters.get(counter, 1)

  @doc "Asserts the network was never touched (the pre-flight failure table)."
  def verify_no_call!(counter) do
    assert attempts(counter) == 0,
           "expected no request, but the stub saw #{attempts(counter)}"
  end

  @doc """
  A `2xx` chat-completions body built from `{role, hex}` pairs, so each
  response-table row is one line.

  Every pair contributes one entry to that role's field list, in the order given;
  each role keeps the order of its first pair. A pair is `{role, hex}` or
  `{role, hex, confidence}`, so a row that documents a confidence does not have to
  hand-build an envelope. Repeating a role builds a multi-entry list (for the
  dedup and truncation rows).

  ## Options

    * `:finish_reason` — defaults to `"stop"`; use `"length"` for the
      truncation row
    * `:usage` — defaults to `#{inspect(@default_usage)}`; `nil` **omits** the
      `usage` key entirely (a missing `usage` yields `nil` counts)

  Options are the **second** argument, so a call that passes both must bracket
  the pairs: `success_body([key: "#A1B2C3"], usage: nil)`. A bare mixed keyword
  list would otherwise arrive here as one list and turn `:usage` into a role.
  """
  def success_body(pairs, opts \\ []) do
    body = %{
      "choices" => [
        %{
          "finish_reason" => Keyword.get(opts, :finish_reason, "stop"),
          "message" => %{"content" => content(pairs)}
        }
      ]
    }

    with_usage(body, opts, @default_usage)
  end

  @doc """
  A `2xx` **Responses-API** body built from the same `{role, hex}` pairs.

  The two surfaces do not share an envelope: a chat-completions body decoded
  against `/v1/responses` produces an empty message rather than an error, which is
  a silently wrong test rather than a failing one. Any row that exercises the
  *default* model spec needs this shape, because `"openai:gpt-4o"` routes here.

  `:usage` behaves as it does on `success_body/2`, defaulting to the Responses
  API's own token key names.
  """
  def responses_body(pairs, opts \\ []) do
    body = %{
      "id" => "resp_stub",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => content(pairs)}]
        }
      ]
    }

    with_usage(body, opts, @default_responses_usage)
  end

  defp with_usage(body, opts, default) do
    case Keyword.fetch(opts, :usage) do
      :error -> Map.put(body, "usage", default)
      {:ok, nil} -> body
      {:ok, usage} -> Map.put(body, "usage", usage)
    end
  end

  # One role-keyed object, encoded as the JSON string both surfaces carry as
  # *text* — which is the case that proves a gateway ignoring the schema still
  # yields the payload.
  defp content(pairs) do
    pairs
    |> Enum.map(&pair!/1)
    |> Enum.group_by(&elem(&1, 0), fn {_role, entry} -> entry end)
    |> Map.new(fn {role, entries} -> {field(role), entries} end)
    |> Jason.encode!()
  end

  # Keyword syntax makes `success_body(key: "#A", usage: nil)` pass the whole
  # keyword list as `pairs`, silently turning `:usage` into a role and emitting a
  # `usage_colors` field. A hex value is always a binary, so catch it here rather
  # than let a test assert against a palette that quietly gained a role.
  defp pair!({role, hex}) when is_atom(role) and is_binary(hex) do
    {role, %{"hex" => hex}}
  end

  defp pair!({role, hex, confidence})
       when is_atom(role) and is_binary(hex) and is_number(confidence) do
    {role, %{"hex" => hex, "confidence" => confidence}}
  end

  defp pair!(other) do
    raise ArgumentError, """
    expected `{role, hex}` or `{role, hex, confidence}` pairs, got: #{inspect(other)}

    Options are the second argument, so bracket a mixed call:

        success_body([key: "#A1B2C3"], usage: nil)
    """
  end

  # The role ↔ field mapping is `:<role>_colors` for all six built-in roles.
  # `Accentone.Prompt.field/1` is the single source of truth; deriving it here
  # deliberately avoids copying the six-row table into a fourth module.
  defp field(role), do: "#{role}_colors"
end
