defmodule Accentone.StubTest do
  use ExUnit.Case, async: true

  alias Accentone.Stub

  # The harness smoke test. Every later stub-driven row depends on all four
  # pieces working together: `elixirc_paths(:test)` loading `test/support`,
  # `Req.Test`'s stub sitting behind the `:req_options` seam, the attempt
  # counter, and `success_body/1`'s envelope shape.

  test "a request through the stub is counted and its body round-trips" do
    counter =
      Stub.install(fn conn ->
        Req.Test.json(conn, Stub.success_body(key: "#A1B2C3", accent: "#D4E5F6"))
      end)

    response =
      Req.request!(
        url: "https://example.test/v1/chat/completions",
        json: %{model: "test"},
        plug: Stub.plug()
      )

    assert Stub.attempts(counter) == 1

    assert %{
             "choices" => [
               %{"finish_reason" => "stop", "message" => %{"content" => content}}
             ]
           } = response.body

    assert %{
             "key_colors" => [%{"hex" => "#A1B2C3"}],
             "accent_colors" => [%{"hex" => "#D4E5F6"}]
           } = Jason.decode!(content)
  end

  test "verify_no_call!/1 passes before a call and fails after one" do
    counter = Stub.install(fn conn -> Req.Test.json(conn, %{}) end)

    Stub.verify_no_call!(counter)
    Req.request!(url: "https://example.test/", plug: Stub.plug())
    assert_raise ExUnit.AssertionError, fn -> Stub.verify_no_call!(counter) end
  end

  test "usage defaults to the documented shape, and nil omits the key" do
    assert %{
             "usage" => %{
               "prompt_tokens" => 380,
               "completion_tokens" => 130,
               "total_tokens" => 510
             }
           } =
             Stub.success_body(key: "#A1B2C3")

    refute Map.has_key?(Stub.success_body([key: "#A1B2C3"], usage: nil), "usage")
  end

  test "a mixed keyword list fails loudly instead of becoming a role" do
    assert_raise ArgumentError, ~r/Options are the second argument/, fn ->
      Stub.success_body(key: "#A1B2C3", usage: nil)
    end
  end

  test "repeating a role builds a multi-entry list in the order given" do
    assert %{"choices" => [%{"message" => %{"content" => content}}]} =
             Stub.success_body([{:key, "#AAAAAA"}, {:key, "#BBBBBB"}])

    assert %{"key_colors" => [%{"hex" => "#AAAAAA"}, %{"hex" => "#BBBBBB"}]} =
             Jason.decode!(content)
  end
end
