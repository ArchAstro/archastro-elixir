# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Auth.TokenSet do
  @moduledoc "Rotating bearer credentials returned by login and refresh operations."
  @enforce_keys [:access_token]
  defstruct [:access_token, :refresh_token, :expires_at, :expires_in, :user]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | integer() | nil,
          expires_in: non_neg_integer() | nil,
          user: ArchAstro.SDK.Types.User.t() | nil
        }

  @type input ::
          ArchAstro.SDK.JSON.object() | %{optional(atom()) => ArchAstro.SDK.JSON.t()} | struct()

  @spec from_map(input()) :: t()
  def from_map(%_module{} = data), do: data |> Map.from_struct() |> from_map()

  def from_map(data) do
    expiry =
      data["expires_at"] || data[:expires_at] || data["token_expiry"] || data[:token_expiry]

    access_token = data["access_token"] || data[:access_token] || data["token"] || data[:token]
    refresh_token = data["refresh_token"] || data[:refresh_token]
    expires_in = data["expires_in"] || data[:expires_in]
    user = data["user"] || data[:user]

    token_set =
      normalize(%__MODULE__{
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: normalize_expiry(expiry),
        expires_in: normalize_expires_in(expires_in),
        user: normalize_user(user)
      })

    unless valid?(token_set) do
      raise ArgumentError, "token set requires a non-empty string access token"
    end

    token_set
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = tokens) do
    is_binary(tokens.access_token) and tokens.access_token != "" and
      (is_nil(tokens.refresh_token) or is_binary(tokens.refresh_token)) and
      (is_nil(tokens.expires_at) or is_integer(tokens.expires_at) or
         match?(%DateTime{}, tokens.expires_at)) and
      (is_nil(tokens.expires_in) or
         (is_integer(tokens.expires_in) and tokens.expires_in >= 0)) and
      (is_nil(tokens.user) or match?(%ArchAstro.SDK.Types.User{}, tokens.user))
  end

  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{expires_at: nil, expires_in: seconds} = tokens)
      when is_integer(seconds) and seconds >= 0 do
    %{tokens | expires_at: DateTime.add(DateTime.utc_now(), seconds, :second)}
  end

  def normalize(%__MODULE__{} = tokens), do: tokens

  defp normalize_expiry(nil), do: nil
  defp normalize_expiry(value) when is_integer(value), do: value
  defp normalize_expiry(%DateTime{} = value), do: value

  defp normalize_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> raise ArgumentError, "token expiry must be an integer or ISO 8601 datetime"
    end
  end

  defp normalize_expiry(_value),
    do: raise(ArgumentError, "token expiry must be an integer or ISO 8601 datetime")

  defp normalize_expires_in(nil), do: nil
  defp normalize_expires_in(value) when is_integer(value) and value >= 0, do: value

  defp normalize_expires_in(_value),
    do: raise(ArgumentError, "expires_in must be a non-negative integer")

  defp normalize_user(nil), do: nil
  defp normalize_user(%ArchAstro.SDK.Types.User{} = user), do: user
  defp normalize_user(user) when is_map(user), do: ArchAstro.SDK.Types.User.from_map(user)
  defp normalize_user(_user), do: raise(ArgumentError, "token user must be a user object")
end

defimpl Inspect, for: ArchAstro.SDK.Auth.TokenSet do
  import Inspect.Algebra

  def inspect(value, opts) do
    concat([
      "#ArchAstro.SDK.Auth.TokenSet<access_token: [REDACTED], refresh_token: ",
      if(value.refresh_token, do: "[REDACTED]", else: "nil"),
      ", expires_at: ",
      to_doc(value.expires_at, opts),
      ">"
    ])
  end
end

defmodule ArchAstro.SDK.Authorization do
  @moduledoc "Resolved request authorization returned by a token-server provider."
  @enforce_keys [:headers, :generation, :refreshable]
  defstruct [:headers, :generation, :refreshable, :expires_at]

  @type t :: %__MODULE__{
          headers: [{String.t(), String.t()}],
          generation: non_neg_integer(),
          refreshable: boolean(),
          expires_at: DateTime.t() | nil
        }
end

defimpl Inspect, for: ArchAstro.SDK.Authorization do
  def inspect(value, _opts),
    do:
      "#ArchAstro.SDK.Authorization<headers: [REDACTED], generation: #{value.generation}, refreshable: #{value.refreshable}>"
end
