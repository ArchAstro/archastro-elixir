#!/usr/bin/env bash
# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.
set -euo pipefail
cd "$(dirname "$0")/.."

SPEC_DEST="specs/platform-openapi.json"
CONFIG="scripts/sdk-generator-config.json"

if [[ "${1:-}" == "--local" ]]; then
  SRC="${2:?usage: regenerate_sdk.sh --local <archastro-openapi-checkout>}"
  mkdir -p specs
  cp "$SRC/specs/platform-openapi.json" "$SPEC_DEST"
else
  REF="${ARCHASTRO_OPENAPI_REF:-main}"
  mkdir -p specs
  curl -fsSL "https://raw.githubusercontent.com/ArchAstro/archastro-openapi/$REF/specs/platform-openapi.json" -o "$SPEC_DEST"
fi

GENERATOR="${ARCHASTRO_SDK_GENERATOR_BIN:-node_modules/.bin/sdk-generator}"
"$GENERATOR" --spec "$SPEC_DEST" --config "$CONFIG" --lang elixir --out .
"$GENERATOR" --spec "$SPEC_DEST" --config "$CONFIG" --lang contract-tests-elixir --out .

mix format
echo "Done. Run mix test."
