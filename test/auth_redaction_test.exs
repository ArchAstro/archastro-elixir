defmodule ArchAstro.SDK.AuthRedactionTest do
  use ExUnit.Case, async: true

  test "generated credential structs redact secrets when inspected" do
    tokens = %ArchAstro.SDK.Types.AuthTokens{
      expires_in: 3_600,
      refresh_token: "refresh-secret",
      token: "access-secret",
      token_type: "Bearer",
      user: nil
    }

    inspected = inspect(tokens)
    assert inspected == "#ArchAstro.SDK.Types.AuthTokens<[REDACTED]>"
    refute inspected =~ "access-secret"
    refute inspected =~ "refresh-secret"
  end
end
