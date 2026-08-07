# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.
Code.require_file("support/contract_support.ex", __DIR__)

exclude =
  if System.get_env("ARCHASTRO_RUN_CHANNEL_CONTRACT_TESTS") in ["1", "true", "TRUE", "yes", "YES"],
    do: [],
    else: [:channel_contract]

ExUnit.start(exclude: exclude)
ExUnit.after_suite(fn _ -> ArchAstro.ContractSupport.stop_servers() end)
