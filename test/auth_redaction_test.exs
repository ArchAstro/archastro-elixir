defmodule ArchAstro.AuthRedactionTest do
  use ExUnit.Case, async: true

  test "generated credential structs redact secrets when inspected" do
    tokens = %ArchAstro.Types.AuthTokens{
      expires_in: 3_600,
      refresh_token: "refresh-secret",
      token: "access-secret",
      token_type: "Bearer",
      user: nil
    }

    inspected = inspect(tokens)
    assert inspected == "#ArchAstro.Types.AuthTokens<[REDACTED]>"
    refute inspected =~ "access-secret"
    refute inspected =~ "refresh-secret"
  end
end
