defmodule Accentone.Model do
  @moduledoc false

  # The one place a `:model` spec is interpreted, because three callers need the
  # same answer and must not each parse it: `Accentone.Config` gates
  # `api_key: nil` on the provider (only the adapters that suppress the
  # `authorization` header can send no credential), `Accentone.Client` asks the
  # provider module whether it declares a structured-output mode knob, and the
  # plaintext warning needs the endpoint.
  #
  # The spec vocabulary is `ReqLLM`'s own and nothing here invents a fourth form:
  # a `"provider:id"` string, a `{provider, opts}` tuple, or a
  # `%{provider: p, id: id}` map.
  #
  # Two rules are load-bearing and neither is obvious:
  #
  #   * `LLMDB.Spec.parse_spec/1` is tried first, because it is the thing that
  #     resolves bare model names and the `"id@provider"` form. It is *not*
  #     sufficient, and the case it misses is the local one: it answers
  #     `{:error, :unknown_provider}` for a provider LLMDB carries no catalog
  #     entries for, so `"ollama:llama3"` is an error to it and a working spec to
  #     `ReqLLM`.
  #   * The fallback split uses `String.to_existing_atom/1`, never
  #     `String.to_atom/1`. A `:model` value is caller input, and minting atoms
  #     from it would leak a permanent atom per typo.
  #
  # An id the catalog does not know is rewritten into `ReqLLM`'s inline-map form,
  # because `ReqLLM` logs "Using unverified model" on *every* call for an
  # uncatalogued spec — and the uncatalogued case is the advertised local-model
  # path, so without this every local call warns. A catalogued spec is passed
  # through untouched, in the shape the caller wrote: the inline form drops
  # `capabilities` and `extra.wire`, and `extra.wire` is what decides whether
  # OpenAI is called on `/v1/responses` or `/v1/chat/completions`.

  @type t :: %__MODULE__{
          spec: term(),
          provider: atom(),
          id: binary(),
          module: module(),
          base_url: binary() | nil
        }

  defstruct [:spec, :provider, :id, :module, :base_url]

  @doc """
  Resolve a model spec into the spec to hand `ReqLLM`, its provider, its id, its
  provider module, and its resolved endpoint.

  Returns `{:error, {:invalid_option, :model, spec}}` for a spec that names no
  provider, names a provider `ReqLLM` does not implement, or names no model —
  every one of which is a pre-flight typo rather than a request.
  """
  @spec resolve(term()) :: {:ok, t()} | {:error, Accentone.error_reason()}
  def resolve(spec) do
    with {:ok, provider, id, base_url} <- parts(spec),
         {:ok, module} <- provider_module(provider, spec) do
      {:ok,
       %__MODULE__{
         spec: normalized(spec, provider, id, base_url),
         provider: provider,
         id: id,
         module: module,
         base_url: base_url || default_base_url(module)
       }}
    end
  end

  @doc """
  A stable `"provider:id"` label for telemetry.

  Deliberately not the spec itself and deliberately not the endpoint: a
  caller-supplied `base_url` can carry a credential in a query parameter, so
  telemetry metadata must not be built from it.
  """
  @spec label(t()) :: binary()
  def label(%__MODULE__{provider: provider, id: id}), do: "#{provider}:#{id}"

  # -- the accepted shapes --------------------------------------------------

  defp parts(spec) when is_binary(spec) do
    case LLMDB.Spec.parse_spec(spec) do
      {:ok, {provider, id}} -> {:ok, provider, id, nil}
      {:error, _reason} -> split(spec)
    end
  end

  defp parts({provider, opts}) when is_atom(provider) and is_list(opts) do
    with {:ok, id} <- id(opts, {provider, opts}) do
      {:ok, provider, id, Keyword.get(opts, :base_url)}
    end
  end

  defp parts(%{provider: provider} = map) when is_atom(provider) do
    with {:ok, id} <- id(map, map) do
      {:ok, provider, id, Map.get(map, :base_url)}
    end
  end

  defp parts(spec), do: {:error, {:invalid_option, :model, spec}}

  # `"provider:id"`, the form the README documents. The first `:` is the split:
  # a model id may contain one (`openrouter`'s `"vendor/model:free"` shape does
  # not need it, but nothing forbids it) and a provider name may not.
  defp split(spec) do
    with [provider, id] when id != "" <- String.split(spec, ":", parts: 2),
         {:ok, atom} <- existing_atom(provider) do
      {:ok, atom, id, nil}
    else
      _other -> {:error, {:invalid_option, :model, spec}}
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # `ReqLLM`'s inline form takes `:id`, and its own docs accept `:model` too.
  defp id(container, spec) when is_list(container) do
    value(Keyword.get(container, :id) || Keyword.get(container, :model), spec)
  end

  defp id(container, spec), do: value(Map.get(container, :id) || Map.get(container, :model), spec)

  defp value(id, _spec) when is_binary(id) and id != "", do: {:ok, id}
  defp value(_other, spec), do: {:error, {:invalid_option, :model, spec}}

  # -- provider and endpoint ------------------------------------------------

  defp provider_module(provider, spec) do
    case ReqLLM.Providers.get(provider) do
      {:ok, module} -> {:ok, module}
      {:error, _error} -> {:error, {:invalid_option, :model, spec}}
    end
  end

  defp normalized(spec, provider, id, base_url) do
    if catalogued?(provider, id), do: spec, else: inline(provider, id, base_url)
  end

  defp catalogued?(provider, id), do: match?({:ok, _model}, LLMDB.model({provider, id}))

  defp inline(provider, id, nil), do: %{provider: provider, id: id}
  defp inline(provider, id, base_url), do: %{provider: provider, id: id, base_url: base_url}

  defp default_base_url(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :default_base_url, 0) do
      module.default_base_url()
    end
  end
end
