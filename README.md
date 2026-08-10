# archastro-elixir

Elixir SDK for the ArchAstro Platform API, generated from the canonical
OpenAPI specification with a hand-maintained OTP runtime.

The SDK uses immutable clients. Mutable access/refresh-token state lives in a
replaceable `ArchAstro.TokenServer` implementation, so an API call can refresh
a token without returning a replacement client.

HTTP transport is provided by Req/Finch. Pass a configured `Req.Request` with
the `:req` client option to select a custom Req adapter, Plug test transport,
timeouts, proxies, or middleware without changing generated resources.

## Installation

Add `archastro` to `mix.exs`:

```elixir
def deps do
  [{:archastro, "~> 0.2"}]
end
```

## Credential modes

Start the built-in token server under your application's supervisor.

Secret-key server client:

```elixir
children = [
  {ArchAstro.TokenServer.Default,
   name: MyApp.ArchAstroTokens,
   mode: {:secret_key, System.fetch_env!("ARCHASTRO_SECRET_KEY")}}
]

{:ok, client} = ArchAstro.Client.for_server(MyApp.ArchAstroTokens)
```

A secret-key server rejects `Client.for_session/3` and session writes. This
prevents a privileged credential from silently being used for a user session.

System-user client with a non-expiring bearer token:

```elixir
{ArchAstro.TokenServer.Default,
 name: MyApp.ArchAstroTokens,
 mode:
   {:system_user,
    publishable_key: System.fetch_env!("ARCHASTRO_PUBLISHABLE_KEY"),
    access_token: System.fetch_env!("ARCHASTRO_SYSTEM_USER_TOKEN")}}
```

Direct access/refresh-token client:

```elixir
{ArchAstro.TokenServer.Default,
 name: MyApp.ArchAstroTokens,
 mode:
   {:bearer,
    publishable_key: System.fetch_env!("ARCHASTRO_PUBLISHABLE_KEY"),
    access_token: restored_access_token,
    refresh_token: restored_refresh_token}}
```

The direct bearer pair is mutable state owned by the token server and refreshes
in place; callers continue using the same `ArchAstro.Client` value.

Multi-user LiveView application:

```elixir
{ArchAstro.TokenServer.Default,
 name: MyApp.ArchAstroTokens,
 mode: {:sessions, publishable_key: System.fetch_env!("ARCHASTRO_PUBLISHABLE_KEY")}}

# In the LiveView/login process. Use the Phoenix session ID or another opaque,
# application-controlled session identifier — never the email address.
{:ok, client} =
  ArchAstro.Session.login(
    MyApp.ArchAstroTokens,
    socket.id,
    email,
    password
  )
```

The email and password are sent directly by the calling process and discarded.
Only returned access/refresh tokens are saved under the opaque session ID in a
protected ETS table. A later request can obtain the same scoped client with:

```elixir
{:ok, client} = ArchAstro.Client.for_session(MyApp.ArchAstroTokens, socket.id)
{:ok, agents} = ArchAstro.V1.Agents.list(client)
```

On a 401, concurrent callers for the same session share one refresh. Refreshes
for different sessions run concurrently. The token server generation-fences
the result so a concurrent login cannot be overwritten by a stale refresh.
Clients remain unchanged throughout.

For durable sessions, implement `ArchAstro.TokenServer.Store` and pass
`store: {MyStore, store_reference}`. To replace all credential-state behavior,
implement the `ArchAstro.TokenServer` behaviour and pass `{MyProvider, ref}` to
the client factories.

## Realtime channels

`ArchAstro.Socket` is a small wrapper around
[`Slipstream`](https://hex.pm/packages/slipstream), a focused Phoenix Channels
client built on Mint WebSocket. It supports multiple topics, automatic
reconnect/rejoin, generated typed payload decoding, and re-resolves bearer
credentials from the token server on reconnect.

```elixir
{:ok, socket} = ArchAstro.Socket.start_link(client)
{:ok, chat} = ArchAstro.Channels.ApiChat.join_team_thread(socket, team_id, thread_id)

:ok = ArchAstro.Channels.ApiChat.subscribe_message_added(chat, self())

receive do
  {:archastro_channel, ^chat, "message_added", payload} -> IO.inspect(payload)
end
```

WebSockets require a bearer credential; secret-key-only clients return
`:websocket_requires_bearer_token`.

## Regeneration and tests

Generated code lives in `lib/archastro/generated`; handwritten runtime modules
live directly in `lib/archastro`.

```bash
npm ci
./scripts/regenerate_sdk.sh --local ../archastro-openapi
mix test
ARCHASTRO_RUN_CHANNEL_CONTRACT_TESTS=true mix test test/contract/channels
```

REST contract tests start Prism against `specs/platform-openapi.json`. Channel
contract tests opt into the same `@archastro/channel-harness` service used by
the TypeScript, Python, Swift, and Go SDKs. Override binaries with `PRISM_BIN`
and `ARCHASTRO_HARNESS_BIN` when needed.
