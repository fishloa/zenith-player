#!/bin/bash
# Called by the "Build zenith-media (Rust)" Run Script phase of each app target.
# Builds libzenith_media.a for the SDK/arch being built; the project sets
# ZM_RUST_TRIPLE per SDK and ZM_RUST_PROFILE per configuration, and links from
# target/$ZM_RUST_TRIPLE/$ZM_RUST_PROFILE via LIBRARY_SEARCH_PATHS.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")"
: "${ZM_RUST_TRIPLE:?set by the Xcode project per SDK}"
rustup target list --installed | grep -qx "$ZM_RUST_TRIPLE" || rustup target add "$ZM_RUST_TRIPLE"
if [ "${ZM_RUST_PROFILE:-release}" = release ]; then
  cargo build --release --target "$ZM_RUST_TRIPLE"
else
  cargo build --target "$ZM_RUST_TRIPLE"
fi
