# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.TokenServerTest do
  use ExUnit.Case, async: true

  alias ArchAstro.SDK.Auth.TokenSet
  alias ArchAstro.SDK.{Client, HTTP, TokenServer}

  defmodule ControlledStore do
    @behaviour ArchAstro.SDK.TokenServer.Store

    @impl true
    def load(agent, id) do
      Agent.get(agent, fn state ->
        case state.tokens[id] do
          nil -> :not_found
          tokens -> {:ok, tokens}
        end
      end)
    end

    @impl true
    def save(agent, id, tokens) do
      Agent.get_and_update(agent, fn state ->
        if state.fail_save,
          do: {{:error, :store_unavailable}, state},
          else: {:ok, put_in(state, [:tokens, id], tokens)}
      end)
    end

    @impl true
    def delete(agent, id) do
      Agent.get_and_update(agent, fn state ->
        if state.fail_delete,
          do: {{:error, :store_unavailable}, state},
          else: {:ok, %{state | tokens: Map.delete(state.tokens, id)}}
      end)
    end
  end

  test "secret keys are server-only and cannot be used with session IDs" do
    server = start_supervised!({TokenServer.Default, mode: {:secret_key, "sk_test"}})

    assert {:ok, client} = Client.for_server(server)
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert {"x-archastro-api-key", "sk_test"} in authorization.headers

    assert {:error, {:scope_not_supported, :secret_key, {:session, "live-session"}}} =
             Client.for_session(server, "live-session")

    assert {:error, {:scope_not_supported, :secret_key, :session}} =
             TokenServer.put_session(server, "live-session", %TokenSet{access_token: "token"})

    refute inspect(:sys.get_state(server)) =~ "sk_test"
  end

  test "system-user access tokens are non-refreshing server credentials" do
    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:system_user, publishable_key: "pk_test", access_token: "system-user-token"}}
      )

    assert {:ok, client} = Client.for_server(server)
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    refute authorization.refreshable
    assert {"authorization", "Bearer system-user-token"} in authorization.headers
    refute inspect(:sys.get_state(server)) =~ "system-user-token"
  end

  test "a direct bearer access/refresh pair is a refreshable server credential" do
    server =
      start_supervised!(
        {TokenServer.Default,
         mode:
           {:bearer,
            publishable_key: "pk_test", access_token: "access-token", refresh_token: "refresh-token"}}
      )

    assert {:ok, client} = Client.for_server(server)
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert authorization.refreshable
    assert {"authorization", "Bearer access-token"} in authorization.headers
    refute Map.has_key?(:sys.get_state(server).mode, :tokens)
  end

  test "malformed token sets are rejected without crashing the owner" do
    assert %TokenSet{expires_in: 3600} =
             TokenSet.from_map(%{"access_token" => "access", "expires_in" => 3600})

    assert_raise ArgumentError, ~r/non-empty string access token/, fn ->
      TokenSet.from_map(%{"refresh_token" => "refresh"})
    end

    server =
      start_supervised!({TokenServer.Default, mode: {:sessions, publishable_key: "pk_test"}})

    assert {:error, :invalid_token_set} =
             TokenServer.put_session(server, "session", %TokenSet{access_token: nil})

    assert {:error, :invalid_token_set} =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "access",
               refresh_token: 42
             })

    assert Process.alive?(server)
  end

  test "multi-user sessions are stored by opaque session ID, not username or password" do
    server =
      start_supervised!({TokenServer.Default, mode: {:sessions, publishable_key: "pk_test"}})

    assert :ok =
             TokenServer.put_session(server, "lv:browser-session", %TokenSet{
               access_token: "access-one",
               refresh_token: "refresh-one"
             })

    assert {:ok, client} = Client.for_session(server, "lv:browser-session")
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert {"authorization", "Bearer access-one"} in authorization.headers

    state = :sys.get_state(server)
    assert state.mode == %{kind: :sessions, publishable_key: "pk_test"}
    refute inspect(state) =~ "password"
    refute inspect(state) =~ "@"
  end

  test "session mutations propagate store failures without diverging ETS" do
    store =
      start_supervised!({Agent, fn -> %{tokens: %{}, fail_save: true, fail_delete: false} end})

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"}, store: {ControlledStore, store}}
      )

    tokens = %TokenSet{access_token: "access", refresh_token: "refresh"}

    assert {:error, {:token_store, :store_unavailable}} =
             TokenServer.put_session(server, "session", tokens)

    assert {:error, :session_not_found} = Client.for_session(server, "session")

    Agent.update(store, &%{&1 | fail_save: false})
    assert :ok = TokenServer.put_session(server, "session", tokens)
    assert {:ok, _client} = Client.for_session(server, "session")

    Agent.update(store, &%{&1 | fail_delete: true})

    assert {:error, {:token_store, :store_unavailable}} =
             TokenServer.delete_session(server, "session")

    assert {:ok, _client} = Client.for_session(server, "session")
  end

  test "refresh does not replace ETS tokens when durable save fails" do
    store =
      start_supervised!({Agent, fn -> %{tokens: %{}, fail_save: false, fail_delete: false} end})

    plug = fn conn ->
      Req.Test.json(conn, %{"access_token" => "new-access", "refresh_token" => "new-refresh"})
    end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"},
         store: {ControlledStore, store},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "old-access",
               refresh_token: "old-refresh"
             })

    assert {:ok, client} = Client.for_session(server, "session")
    assert {:ok, before_refresh} = TokenServer.authorization(client.token_binding)
    Agent.update(store, &%{&1 | fail_save: true})

    assert {:error, {:token_store, :store_unavailable}} =
             TokenServer.refresh_if_current(client.token_binding, before_refresh.generation)

    assert {:ok, after_refresh} = TokenServer.authorization(client.token_binding)
    assert after_refresh.generation == before_refresh.generation
    assert {"authorization", "Bearer old-access"} in after_refresh.headers
  end

  test "deleting a session fences an in-flight refresh from restoring it" do
    caller = self()

    plug = fn conn ->
      send(caller, {:refresh_started, self()})
      receive do: (:finish_refresh -> :ok)
      Req.Test.json(conn, %{"access_token" => "new-access", "refresh_token" => "new-refresh"})
    end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "old-access",
               refresh_token: "old-refresh"
             })

    assert {:ok, client} = Client.for_session(server, "session")
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)

    refresh =
      Task.async(fn ->
        TokenServer.refresh_if_current(client.token_binding, authorization.generation)
      end)

    assert_receive {:refresh_started, refresh_process}
    assert :ok = TokenServer.delete_session(server, "session")
    send(refresh_process, :finish_refresh)

    assert {:error, :signed_out} = Task.await(refresh)
    assert {:error, :session_not_found} = Client.for_session(server, "session")
  end

  test "delete and re-login never reuse an in-flight refresh generation" do
    caller = self()

    plug = fn conn ->
      send(caller, {:old_refresh_started, self()})
      receive do: (:finish_old_refresh -> :ok)
      Req.Test.json(conn, %{"access_token" => "stale-access", "refresh_token" => "stale-refresh"})
    end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "old-access",
               refresh_token: "old-refresh"
             })

    assert {:ok, client} = Client.for_session(server, "session")
    assert {:ok, old_authorization} = TokenServer.authorization(client.token_binding)

    refresh =
      Task.async(fn ->
        TokenServer.refresh_if_current(client.token_binding, old_authorization.generation)
      end)

    assert_receive {:old_refresh_started, refresh_process}
    assert :ok = TokenServer.delete_session(server, "session")

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "new-login-access",
               refresh_token: "new-login-refresh"
             })

    send(refresh_process, :finish_old_refresh)
    assert {:ok, current} = Task.await(refresh)
    assert {"authorization", "Bearer new-login-access"} in current.headers

    assert {:ok, after_refresh} = TokenServer.authorization(client.token_binding)
    assert {"authorization", "Bearer new-login-access"} in after_refresh.headers
  end

  test "refreshes from different session generations are not coalesced" do
    caller = self()

    plug = fn conn ->
      %{"refresh_token" => refresh_token} = Jason.decode!(Req.Test.raw_body(conn))
      send(caller, {:refresh_started, refresh_token, self()})
      receive do: (:finish_refresh -> :ok)

      Req.Test.json(conn, %{
        "access_token" => "refreshed-#{refresh_token}",
        "refresh_token" => "rotated-#{refresh_token}"
      })
    end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "generation-zero",
               refresh_token: "refresh-zero"
             })

    assert {:ok, client} = Client.for_session(server, "session")
    assert {:ok, generation_zero} = TokenServer.authorization(client.token_binding)

    first =
      Task.async(fn ->
        TokenServer.refresh_if_current(client.token_binding, generation_zero.generation)
      end)

    assert_receive {:refresh_started, "refresh-zero", first_process}

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "generation-one",
               refresh_token: "refresh-one"
             })

    assert {:ok, generation_one} = TokenServer.authorization(client.token_binding)

    second =
      Task.async(fn ->
        TokenServer.refresh_if_current(client.token_binding, generation_one.generation)
      end)

    assert_receive {:refresh_started, "refresh-one", second_process}
    send(first_process, :finish_refresh)
    assert {:ok, current} = Task.await(first)
    assert {"authorization", "Bearer generation-one"} in current.headers

    send(second_process, :finish_refresh)
    assert {:ok, refreshed} = Task.await(second)
    assert {"authorization", "Bearer refreshed-refresh-one"} in refreshed.headers
  end

  test "an invalid refresh token deletes its durable session" do
    store =
      start_supervised!({Agent, fn -> %{tokens: %{}, fail_save: false, fail_delete: false} end})

    plug = fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"},
         store: {ControlledStore, store},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             TokenServer.put_session(server, "session", %TokenSet{
               access_token: "old-access",
               refresh_token: "invalid-refresh"
             })

    assert {:ok, client} = Client.for_session(server, "session")
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)

    assert {:error, :reauthentication_required} =
             TokenServer.refresh_if_current(client.token_binding, authorization.generation)

    assert Agent.get(store, & &1.tokens) == %{}
    assert {:error, :session_not_found} = Client.for_session(server, "session")
  end

  test "LiveView-style password login stores only returned session tokens" do
    plug = fn conn ->
      assert conn.request_path == "/api/v1/auth/login"

      assert Jason.decode!(Req.Test.raw_body(conn)) == %{
               "email" => "person@example.com",
               "password" => "one-use-password"
             }

      Req.Test.json(conn, %{
        "token" => "logged-in-access",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "refresh_token" => "logged-in-refresh",
        "user" => %{"id" => "usr_test"}
      })
    end

    server =
      start_supervised!({TokenServer.Default, mode: {:sessions, publishable_key: "pk_test"}})

    assert {:ok, client} =
             ArchAstro.SDK.Session.login(
               server,
               "lv-session-id",
               "person@example.com",
               "one-use-password",
               base_url: "http://test",
               req: Req.new(plug: plug, retry: false)
             )

    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert {"authorization", "Bearer logged-in-access"} in authorization.headers

    state = :sys.get_state(server)
    refute inspect(state) =~ "person@example.com"
    refute inspect(state) =~ "one-use-password"
  end

  test "one 401 refresh updates external state while the client remains unchanged" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      case conn.request_path do
        "/api/v1/auth/refresh" ->
          Agent.update(counter, &(&1 + 1))

          Req.Test.json(conn, %{
            "access_token" => "access-two",
            "refresh_token" => "refresh-two"
          })

        "/resource" ->
          case Plug.Conn.get_req_header(conn, "authorization") do
            ["Bearer access-one"] -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
            ["Bearer access-two"] -> Req.Test.json(conn, %{"ok" => true})
          end
      end
    end

    req = Req.new(plug: plug, retry: false)

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk_test"}, base_url: "http://test", req: req}
      )

    :ok =
      TokenServer.put_session(server, "session", %TokenSet{
        access_token: "access-one",
        refresh_token: "refresh-one"
      })

    {:ok, client} = Client.for_session(server, "session", base_url: "http://test", req: req)
    original = client

    assert {:ok, %{"ok" => true}} = HTTP.request(client, :get, "/resource")
    assert client == original
    assert Agent.get(counter, & &1) == 1
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert {"authorization", "Bearer access-two"} in authorization.headers
  end

  test "concurrent rejected calls share one refresh per session" do
    counter = start_supervised!({Agent, fn -> 0 end})

    refresh_plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(25)
      Req.Test.json(conn, %{"access_token" => "new", "refresh_token" => "rotated"})
    end

    server =
      start_supervised!(
        {TokenServer.Default,
         mode: {:sessions, publishable_key: "pk"},
         base_url: "http://test",
         req: Req.new(plug: refresh_plug, retry: false)}
      )

    :ok =
      TokenServer.put_session(server, "session", %TokenSet{
        access_token: "old",
        refresh_token: "refresh"
      })

    {:ok, client} = Client.for_session(server, "session")
    {:ok, authorization} = TokenServer.authorization(client.token_binding)

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          TokenServer.refresh_if_current(client.token_binding, authorization.generation)
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  defmodule CustomProvider do
    @behaviour ArchAstro.SDK.TokenServer

    def bind(value, scope), do: {:ok, {value, scope}}

    def authorization({_value, scope}),
      do:
        {:ok,
         %ArchAstro.SDK.Authorization{
           headers: [{"x-custom-scope", inspect(scope)}],
           generation: 0,
           refreshable: false
         }}

    def refresh_if_current(_binding, _generation), do: {:error, :not_refreshable}
    def put_session(_server, _id, _tokens), do: :ok
    def delete_session(_server, _id), do: :ok
  end

  test "applications can replace the TokenServer implementation" do
    provider = {:provider, CustomProvider, :custom_state}
    assert {:ok, client} = Client.for_session(provider, "tenant-session")
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert authorization.headers == [{"x-custom-scope", ~s({:session, "tenant-session"})}]

    assert {:error, :invalid_token_set} =
             TokenServer.put_session(
               provider,
               "tenant-session",
               %TokenSet{access_token: nil}
             )
  end

  test "two-tuple GenServer names use the default provider" do
    name = {:global, {:archastro_token_server_test, self()}}

    _server =
      start_supervised!({TokenServer.Default, mode: {:secret_key, "sk_test"}, name: name})

    assert {:ok, client} = Client.for_server(name)
    assert {:ok, authorization} = TokenServer.authorization(client.token_binding)
    assert {"x-archastro-api-key", "sk_test"} in authorization.headers
  end

  test "default requests never follow redirects" do
    # A 3xx from the platform is always wrong; following it can silently turn a
    # token-refresh POST into a body-less GET against the Location target.
    server = start_supervised!({TokenServer.Default, mode: {:secret_key, "sk_test"}})

    assert :sys.get_state(server).req.options[:redirect] == false

    assert {:ok, client} = Client.for_server(server)
    assert client.request.options[:redirect] == false
  end
end
