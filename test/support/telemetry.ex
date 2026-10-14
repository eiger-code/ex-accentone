defmodule Accentone.TelemetryCapture do
  @moduledoc false

  # The telemetry tests attach to the `[:accentone, :analyze, …]` events and
  # assert on the measurements/metadata. The handler is a module function rather
  # than an anonymous one so `:telemetry` does not log its "local function"
  # performance notice on every attach, which would bury the test output.

  @doc """
  Attaches a forwarding handler for `events` and returns its handler id.

  Forwarded messages are `{ref, event, measurements, metadata}` sent to `:pid`
  (the test process by default), filtered by `:filter` — a `(metadata -> boolean)`
  — so a handler attached by one `async: true` test never observes another's
  events.
  """
  def attach(events, opts \\ []) do
    ref = make_ref()
    pid = Keyword.get(opts, :pid, self())
    filter = Keyword.get(opts, :filter, fn _metadata -> true end)

    :telemetry.attach_many(ref, events, &__MODULE__.handle/4, %{
      pid: pid,
      ref: ref,
      filter: filter
    })

    ref
  end

  @doc "Detaches a handler installed by `attach/2`."
  def detach(ref), do: :telemetry.detach(ref)

  @doc false
  def handle(event, measurements, metadata, %{pid: pid, ref: ref, filter: filter}) do
    if filter.(metadata), do: send(pid, {ref, event, measurements, metadata})
    :ok
  end
end
