#!/usr/bin/env bash
# Builds a patched codex core from source for your platform.
# Usage: ./build.sh [rust-v tag]   (default: rust-v0.155.0-alpha.9.2)
set -euo pipefail

TAG="${1:-rust-v0.155.0-alpha.9.2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${CODEX_PLAINTEXT_BUILD_DIR:-$SCRIPT_DIR/build}"
SRC="$WORK/codex"

command -v cargo >/dev/null 2>&1 || {
    echo 'cargo not found — install Rust: https://rustup.rs' >&2; exit 1;
}

mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$TAG" https://github.com/openai/codex.git "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
    git -C "$SRC" checkout --detach "$TAG"
fi

git -C "$SRC" apply --3way "$SCRIPT_DIR/plaintext-delivery.patch"

cd "$SRC/codex-rs"
cargo build --release -p codex-cli
BIN="target/release/codex"
case "$(uname -s)" in
    Darwin) ;;
    *) strip "$BIN" || true ;;
esac

echo
echo "Built $BIN"
echo "Install it by running install.sh with this binary in the same directory:"
echo "  cp \"$BIN\" \"$SCRIPT_DIR\" && \"$SCRIPT_DIR/install.sh\""
