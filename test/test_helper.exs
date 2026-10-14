ExUnit.start()

# The suite runs against `Req.Test` stubs, so no real credential is used — but
# resolution fails fast with `{:error, :missing_api_key}` without one, so the
# app-config layer has to supply a value. This is the only reason the library
# has no `config/` directory: Mix reads `config/*.exs` for the top-level project
# only, so a library's own config files would be dead weight for consumers.
Application.put_env(:accentone, :api_key, "test")
