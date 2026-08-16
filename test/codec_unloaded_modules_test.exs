# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.CodecUnloadedModulesTest do
  # Purging module code is VM-global state; keep this suite out of the
  # concurrent test phase.
  use ExUnit.Case, async: false

  alias ArchAstro.SDK.Codec

  @sentinel :__archastro_unset__

  test "generated input/params structs encode identically when their modules are not loaded" do
    modules = generated_input_modules()
    assert length(modules) > 150

    for module <- modules do
      {:module, ^module} = Code.ensure_loaded(module)
      value = struct(module)
      expected = Codec.encode(value)

      unload(module)
      actual = Codec.encode(value)

      assert actual == expected,
             "#{inspect(module)} encoded differently when its module was not loaded: " <>
               "#{inspect(actual)} vs #{inspect(expected)}"

      assert_wire_clean(actual, module)
      {:module, ^module} = Code.ensure_loaded(module)
    end
  end

  test "renamed fields keep their wire names when the module is not loaded" do
    module = ArchAstro.SDK.Types.Operations.PostApiV1AuthRegister.AuthInput
    {:module, ^module} = Code.ensure_loaded(module)
    value = struct(module, alias_: "my-alias")

    unload(module)
    encoded = Codec.encode(value)
    {:module, ^module} = Code.ensure_loaded(module)

    assert encoded["alias"] == "my-alias"
    refute Map.has_key?(encoded, "alias_")
    refute Map.has_key?(encoded, :alias_)
  end

  defp generated_input_modules do
    {:ok, modules} = :application.get_key(:archastro, :modules)

    Enum.filter(modules, fn module ->
      name = Atom.to_string(module)

      String.starts_with?(name, "Elixir.ArchAstro.SDK.") and
        Regex.match?(~r/\.(?:[A-Za-z0-9]*Input|Params)$/, name)
    end)
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    refute function_exported?(module, :to_map, 1)
  end

  defp assert_wire_clean(value, module) when is_map(value) do
    Enum.each(value, fn {key, item} ->
      assert is_binary(key), "#{inspect(module)} leaked non-string map key #{inspect(key)}"
      assert_wire_clean(item, module)
    end)
  end

  defp assert_wire_clean(value, module) when is_list(value) do
    Enum.each(value, &assert_wire_clean(&1, module))
  end

  defp assert_wire_clean(value, module) do
    refute value in [@sentinel, "__archastro_unset__"],
           "#{inspect(module)} leaked the unset sentinel onto the wire"
  end
end
