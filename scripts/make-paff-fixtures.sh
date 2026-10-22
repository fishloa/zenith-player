#!/bin/bash
# Build PAFF (field-coded H.264) fixtures with tools/paff-gen (spec-built, MIT OR Apache-2.0).
# usage: scripts/make-paff-fixtures.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/testdata/paff"; mkdir -p "$OUT"
(cd "$ROOT/tools/paff-gen" && cargo build -q --release)
"$ROOT/tools/paff-gen/target/release/paff-gen" "$OUT/tff" --frames 12
"$ROOT/tools/paff-gen/target/release/paff-gen" "$OUT/bff" --frames 12 --bff
