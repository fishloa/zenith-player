#!/bin/bash
# Host test run for ZenithMedia: Rust crate tests, then Swift package tests
# linked against the host build of libzenith_media.a.
# usage: [ZM_SANITIZE=thread] scripts/test-zenith-media.sh [swift test filter]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ZenithMedia/rust"
cargo test --release
cargo build --release
cd "$ROOT/ZenithMedia"
swift test -c release ${ZM_SANITIZE:+--sanitize=$ZM_SANITIZE} -Xlinker -L"$ROOT/ZenithMedia/rust/target/release" ${1:+--filter "$1"}
