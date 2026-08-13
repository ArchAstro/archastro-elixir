# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.TokenServer.Default do
  @moduledoc """
  GenServer-backed credential provider with a private ETS credential cache.

  It supports four intentionally disjoint modes: secret-key, system-user,
  direct bearer, and publishable-key multi-session. Refresh work runs outside the GenServer;
  callers for one session share a generation-fenced refresh while different
  sessions refresh concurrently.
  """

  use GenServer
  @behaviour ArchAstro.SDK.TokenServer

  alias ArchAstro.SDK.Auth.TokenSet
  alias ArchAstro.SDK.Authorization

  @type mode ::
          {:secret_key, String.t()}
          | {:system_user, keyword()}
          | {:bearer, keyword()}
          | {:sessions, keyword()}

  def start_link(opts) do
    {gen_opts, init_opts} =
      Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])

    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @impl ArchAstro.SDK.TokenServer
  def bind(server, scope) do
    with :ok <- GenServer.call(server, {:bind, scope}) do
      {:ok, {server, scope}}
    end
  end

  @impl ArchAstro.SDK.TokenServer
  def authorization({server, scope}), do: GenServer.call(server, {:authorization, scope})

  @impl ArchAstro.SDK.TokenServer
  def refresh_if_current({server, scope}, generation),
    do: GenServer.call(server, {:refresh, scope, generation}, :infinity)

  @impl ArchAstro.SDK.TokenServer
  def put_session(server, session_id, %TokenSet{} = tokens) do
    if TokenSet.valid?(tokens),
      do: GenServer.call(server, {:put_session, session_id, TokenSet.normalize(tokens)}),
      else: {:error, :invalid_token_set}
  end

  @impl ArchAstro.SDK.TokenServer
  def delete_session(server, session_id),
    do: GenServer.call(server, {:delete_session, session_id})

  @impl GenServer
  def init(opts) do
    mode = normalize_mode(Keyword.fetch!(opts, :mode))
    table_opts = [:set, :private, read_concurrency: true, write_concurrency: true]
    table_opts = if opts[:table], do: [:named_table | table_opts], else: table_opts
    table = :ets.new(opts[:table] || __MODULE__, table_opts)

    mode =
      case mode do
        %{kind: :secret_key, key: key} ->
          :ets.insert(table, {:server_credentials, %{key: key}})
          %{kind: :secret_key}

        %{kind: :system_user, publishable_key: publishable_key, access_token: access_token} ->
          :ets.insert(
            table,
            {:server_credentials, %{publishable_key: publishable_key, access_token: access_token}}
          )

          %{kind: :system_user}

        %{kind: :bearer, tokens: tokens} = bearer ->
          :ets.insert(table, {:bearer, entry_from_tokens(tokens, 0)})
          Map.delete(bearer, :tokens)

        other ->
          other
      end

    {:ok,
     %{
       mode: mode,
       table: table,
       base_url:
         String.trim_trailing(Keyword.get(opts, :base_url, "https://platform.archastro.ai"), "/"),
       req: Keyword.get(opts, :req, Req.new(retry: false)),
       store: opts[:store],
       inflight: %{}
     }}
  end

  @impl GenServer
  def handle_call({:bind, scope}, _from, state) do
    result =
      case {state.mode.kind, scope} do
        {:secret_key, :server} ->
          :ok

        {:system_user, :server} ->
          :ok

        {:bearer, :server} ->
          :ok

        {:sessions, :public} ->
          :ok

        {:sessions, {:session, id}} when is_binary(id) ->
          case find_session(state, id) do
            {:ok, _} -> :ok
            :not_found -> {:error, :session_not_found}
            {:error, reason} -> {:error, reason}
          end

        {kind, requested} ->
          {:error, {:scope_not_supported, kind, requested}}
      end

    {:reply, result, state}
  end

  def handle_call({:authorization, scope}, _from, state) do
    {:reply, authorization_for(state, scope), state}
  end

  def handle_call({:put_session, session_id, tokens}, _from, %{mode: %{kind: :sessions}} = state)
      when is_binary(session_id) do
    generation = next_generation(state, session_id)

    entry = entry_from_tokens(tokens, generation)

    case persist(state.store, :save, session_id, tokens) do
      :ok ->
        :ets.insert(state.table, {{:session, session_id}, entry})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:token_store, reason}}, state}
    end
  end

  def handle_call({:put_session, _session_id, _tokens}, _from, state) do
    {:reply, {:error, {:scope_not_supported, state.mode.kind, :session}}, state}
  end

  def handle_call({:delete_session, session_id}, _from, %{mode: %{kind: :sessions}} = state) do
    case persist(state.store, :delete, session_id, nil) do
      :ok ->
        :ets.delete(state.table, {:session, session_id})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:token_store, reason}}, state}
    end
  end

  def handle_call({:delete_session, _session_id}, _from, state) do
    {:reply, {:error, {:scope_not_supported, state.mode.kind, :session}}, state}
  end

  def handle_call({:refresh, {:session, session_id}, rejected_generation}, from, state) do
    case find_session(state, session_id) do
      {:ok, %{generation: generation} = entry} when generation != rejected_generation ->
        {:reply, {:ok, session_authorization(state.mode.publishable_key, entry)}, state}

      {:ok, %{refresh_token: nil}} ->
        {:reply, {:error, :reauthentication_required}, state}

      {:ok, entry} ->
        inflight_key = {:session, session_id, rejected_generation}

        case state.inflight[inflight_key] do
          nil ->
            parent = self()

            spawn(fn ->
              result = safely_refresh(state, entry.refresh_token)
              send(parent, {:refresh_result, session_id, rejected_generation, result})
            end)

            inflight = Map.put(state.inflight, inflight_key, %{waiters: [from]})
            {:noreply, %{state | inflight: inflight}}

          current ->
            inflight =
              Map.put(state.inflight, inflight_key, %{current | waiters: [from | current.waiters]})

            {:noreply, %{state | inflight: inflight}}
        end

      :not_found ->
        {:reply, {:error, :signed_out}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:refresh, :server, rejected_generation}, from, %{mode: %{kind: :bearer}} = state) do
    entry = bearer_entry(state)

    cond do
      entry.generation != rejected_generation ->
        {:reply, {:ok, bearer_authorization(state.mode.publishable_key, entry)}, state}

      is_nil(entry.refresh_token) ->
        {:reply, {:error, :reauthentication_required}, state}

      state.inflight[:server] ->
        current = state.inflight.server
        inflight = Map.put(state.inflight, :server, %{current | waiters: [from | current.waiters]})
        {:noreply, %{state | inflight: inflight}}

      true ->
        parent = self()

        spawn(fn ->
          result = safely_refresh(state, entry.refresh_token)
          send(parent, {:bearer_refresh_result, rejected_generation, result})
        end)

        {:noreply, %{state | inflight: Map.put(state.inflight, :server, %{waiters: [from]})}}
    end
  end

  def handle_call({:refresh, scope, _generation}, _from, state) do
    {:reply, {:error, {:not_refreshable, state.mode.kind, scope}}, state}
  end

  @impl GenServer
  def handle_info({:refresh_result, session_id, generation, result}, state) do
    inflight_key = {:session, session_id, generation}
    {inflight, remaining} = Map.pop(state.inflight, inflight_key, %{waiters: []})

    reply =
      case find_session(state, session_id) do
        {:ok, %{generation: current_generation} = current}
        when current_generation != generation ->
          {:ok, session_authorization(state.mode.publishable_key, current)}

        {:ok, _current} ->
          apply_refresh_result(state, session_id, generation, result)

        :not_found ->
          {:error, :signed_out}

        {:error, reason} ->
          {:error, reason}
      end

    Enum.each(inflight.waiters, &GenServer.reply(&1, reply))
    {:noreply, %{state | inflight: remaining}}
  end

  def handle_info({:bearer_refresh_result, generation, result}, state) do
    {inflight, remaining} = Map.pop(state.inflight, :server, %{waiters: []})
    current = bearer_entry(state)

    reply =
      cond do
        current.generation != generation ->
          {:ok, bearer_authorization(state.mode.publishable_key, current)}

        match?({:ok, %TokenSet{}}, result) ->
          {:ok, tokens} = result
          entry = entry_from_tokens(tokens, generation + 1)
          :ets.insert(state.table, {:bearer, entry})
          {:ok, bearer_authorization(state.mode.publishable_key, entry)}

        true ->
          {:error, reason} = result

          if reason in [:unauthorized, :invalid_refresh_token],
            do: {:error, :reauthentication_required},
            else: {:error, reason}
      end

    Enum.each(inflight.waiters, &GenServer.reply(&1, reply))
    {:noreply, %{state | inflight: remaining}}
  end

  defp apply_refresh_result(state, session_id, generation, {:ok, %TokenSet{} = tokens}) do
    entry = entry_from_tokens(tokens, generation + 1)

    case persist(state.store, :save, session_id, tokens) do
      :ok ->
        record_generation(state, session_id, entry.generation)
        :ets.insert(state.table, {{:session, session_id}, entry})
        {:ok, session_authorization(state.mode.publishable_key, entry)}

      {:error, reason} ->
        {:error, {:token_store, reason}}
    end
  end

  defp apply_refresh_result(state, session_id, _generation, {:error, reason}) do
    if reason in [:unauthorized, :invalid_refresh_token] do
      case persist(state.store, :delete, session_id, nil) do
        :ok ->
          :ets.delete(state.table, {:session, session_id})
          {:error, :reauthentication_required}

        {:error, store_reason} ->
          {:error, {:token_store, store_reason}}
      end
    else
      {:error, reason}
    end
  end

  defp authorization_for(%{mode: %{kind: :secret_key}} = state, :server) do
    %{key: key} = server_credentials(state)
    {:ok, authorization([{"x-archastro-api-key", key}], 0, false)}
  end

  defp authorization_for(%{mode: %{kind: :system_user}} = state, :server) do
    credentials = server_credentials(state)

    {:ok,
     authorization(
       [
         {"x-archastro-api-key", credentials.publishable_key},
         {"authorization", "Bearer " <> credentials.access_token}
       ],
       0,
       false
     )}
  end

  defp authorization_for(%{mode: %{kind: :bearer} = mode} = state, :server) do
    {:ok, bearer_authorization(mode.publishable_key, bearer_entry(state))}
  end

  defp authorization_for(%{mode: %{kind: :sessions} = mode}, :public) do
    {:ok, authorization([{"x-archastro-api-key", mode.publishable_key}], 0, false)}
  end

  defp authorization_for(%{mode: %{kind: :sessions} = mode} = state, {:session, id}) do
    case find_session(state, id) do
      {:ok, entry} -> {:ok, session_authorization(mode.publishable_key, entry)}
      :not_found -> {:error, :signed_out}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_for(state, scope),
    do: {:error, {:scope_not_supported, state.mode.kind, scope}}

  defp authorization(headers, generation, refreshable, expires_at \\ nil),
    do: %Authorization{
      headers: headers,
      generation: generation,
      refreshable: refreshable,
      expires_at: datetime_expiry(expires_at)
    }

  defp session_authorization(publishable_key, entry) do
    authorization(
      [
        {"x-archastro-api-key", publishable_key},
        {"authorization", "Bearer " <> entry.access_token}
      ],
      entry.generation,
      not is_nil(entry.refresh_token),
      entry.expires_at
    )
  end

  defp bearer_authorization(publishable_key, entry),
    do: session_authorization(publishable_key, entry)

  defp bearer_entry(state) do
    [{:bearer, entry}] = :ets.lookup(state.table, :bearer)
    entry
  end

  defp server_credentials(state) do
    [{:server_credentials, credentials}] = :ets.lookup(state.table, :server_credentials)
    credentials
  end

  defp find_session(state, id) do
    case :ets.lookup(state.table, {:session, id}) do
      [{{:session, ^id}, entry}] -> {:ok, entry}
      [] -> load_session(state, id)
    end
  end

  defp load_session(%{store: nil}, _id), do: :not_found

  defp load_session(%{store: {module, store_ref}} = state, id) do
    case module.load(store_ref, id) do
      {:ok, %TokenSet{} = tokens} ->
        if TokenSet.valid?(tokens) do
          tokens = TokenSet.normalize(tokens)
          entry = entry_from_tokens(tokens, next_generation(state, id))
          :ets.insert(state.table, {{:session, id}, entry})
          {:ok, entry}
        else
          {:error, :invalid_token_set}
        end

      other ->
        other
    end
  end

  defp persist(nil, _operation, _id, _tokens), do: :ok
  defp persist({module, ref}, :save, id, tokens), do: module.save(ref, id, tokens)
  defp persist({module, ref}, :delete, id, _tokens), do: module.delete(ref, id)

  defp entry_from_tokens(tokens, generation) do
    %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      expires_at: tokens.expires_at,
      expires_in: tokens.expires_in,
      generation: generation,
      user: tokens.user
    }
  end

  defp next_generation(state, session_id) do
    generation =
      case :ets.lookup(state.table, {:generation, session_id}) do
        [{{:generation, ^session_id}, current}] -> current + 1
        [] -> 0
      end

    record_generation(state, session_id, generation)
    generation
  end

  defp record_generation(state, session_id, generation) do
    :ets.insert(state.table, {{:generation, session_id}, generation})
    :ok
  end

  defp datetime_expiry(%DateTime{} = expiry), do: expiry

  defp datetime_expiry(expiry) when is_integer(expiry) do
    case DateTime.from_unix(expiry) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime_expiry(_expiry), do: nil

  defp safely_refresh(state, refresh_token) do
    try do
      url = state.base_url <> "/api/v1/auth/refresh"
      headers = [{"x-archastro-api-key", state.mode.publishable_key}]

      case Req.post(state.req,
             url: url,
             headers: headers,
             json: %{refresh_token: refresh_token},
             retry: false
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, TokenSet.from_map(body)}

        {:ok, %{status: 401}} ->
          {:error, :invalid_refresh_token}

        {:ok, %{status: status}} ->
          {:error, {:refresh_http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp normalize_mode({:secret_key, key}),
    do: %{kind: :secret_key, key: credential!(key, :secret_key)}

  defp normalize_mode({:system_user, opts}) do
    %{
      kind: :system_user,
      publishable_key: credential!(Keyword.fetch!(opts, :publishable_key), :publishable_key),
      access_token: credential!(Keyword.fetch!(opts, :access_token), :access_token)
    }
  end

  defp normalize_mode({:bearer, opts}) do
    tokens =
      TokenSet.from_map(%{
        access_token: Keyword.fetch!(opts, :access_token),
        refresh_token: opts[:refresh_token],
        expires_at: opts[:expires_at],
        expires_in: opts[:expires_in],
        user: opts[:user]
      })

    %{
      kind: :bearer,
      publishable_key: credential!(Keyword.fetch!(opts, :publishable_key), :publishable_key),
      tokens: tokens
    }
  end

  defp normalize_mode({:sessions, opts}) do
    %{
      kind: :sessions,
      publishable_key: credential!(Keyword.fetch!(opts, :publishable_key), :publishable_key)
    }
  end

  defp credential!(value, _name) when is_binary(value) and value != "", do: value

  defp credential!(_value, name),
    do: raise(ArgumentError, "#{name} must be a non-empty string")
end
