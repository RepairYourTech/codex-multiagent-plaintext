#!/usr/bin/env bash
# Installs a patched Codex desktop core that delivers MultiAgentV2 subagent
# tasks as plaintext, so subagents on third-party (OpenAI-compatible) providers
# can read their tasks. Implements the fix described in openai/codex#37197/#46939.
#
# Usage:
#   ./install.sh                      (uses ./codex if present, else downloads)
#   curl -fsSL <raw install.sh url> | bash
#
# Env overrides: CODEX_PLAINTEXT_REPO, CODEX_PLAINTEXT_VERSION,
#                CODEX_PLAINTEXT_INSTALL_DIR
#
# Linux: fully automatic. macOS: installs the binary and prints wiring steps.
set -euo pipefail

REPO="${CODEX_PLAINTEXT_REPO:-RepairYourTech/codex-multiagent-plaintext}"
VERSION="${CODEX_PLAINTEXT_VERSION:-0.155.0-alpha.9.2}"
RELEASE="v${VERSION}-plaintext1"
INSTALL_DIR="${CODEX_PLAINTEXT_INSTALL_DIR:-$HOME/.local/share/codex-plaintext}"
ENVV="CODEX_CLI_PATH=$INSTALL_DIR/bin/codex CODEX_MULTI_AGENT_V2_MESSAGE_DELIVERY=plaintext CODEX_MULTI_AGENT_V2_TOOL_NAMESPACE=agents"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Locate a core binary: local file first, otherwise download the release asset
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS/$ARCH" in
    Linux/x86_64)  PLATFORM="linux-x86_64" ;;
    Linux/aarch64 | Linux/arm64) PLATFORM="linux-aarch64" ;;
    Darwin/arm64)  PLATFORM="macos-arm64" ;;
    Darwin/x86_64) PLATFORM="macos-x86_64" ;;
    *) die "unsupported platform $OS/$ARCH (build from source — see README)" ;;
esac

CORE_SRC=""
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/codex" ]; then
    CORE_SRC="$SCRIPT_DIR/codex"
elif [ -f ./codex ]; then
    CORE_SRC="./codex"
else
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die "no ./codex next to install.sh and no curl/wget to download it"
    ASSET="codex-${VERSION}-${PLATFORM}.tar.gz"
    URL="https://github.com/${REPO}/releases/download/${RELEASE}/${ASSET}"
    say "Downloading $URL"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    if command -v curl >/dev/null 2>&1; then
        curl -fSL "$URL" -o "$TMP/$ASSET"
    else
        wget -q "$URL" -O "$TMP/$ASSET"
    fi
    tar -xzf "$TMP/$ASSET" -C "$TMP"
    CORE_SRC="$(find "$TMP" -type f -name codex -perm -u+x | head -n1)"
    [ -n "$CORE_SRC" ] || die "downloaded archive did not contain a 'codex' binary"
fi

# --- Locate the desktop app's resources directory
RESOURCES=""
for candidate in \
    /opt/codex-desktop/resources \
    /opt/ChatGPT/resources \
    /opt/chatgpt/resources \
    /usr/lib/chatgpt/resources \
    /usr/share/chatgpt/resources \
    "/Applications/ChatGPT.app/Contents/Resources/resources"; do
    if [ -x "$candidate/codex-code-mode-host" ] || [ -x "$candidate/codex-code-mode-host.exe" ]; then
        RESOURCES="$candidate"
        break
    fi
done

# --- Install the patched core (+ mandatory code-mode-host sibling where found)
mkdir -p "$INSTALL_DIR/bin"
cp "$CORE_SRC" "$INSTALL_DIR/bin/codex"
chmod +x "$INSTALL_DIR/bin/codex"
[ -f "$(dirname "$0")/plaintext-delivery.patch" ] \
    && cp "$(dirname "$0")/plaintext-delivery.patch" "$INSTALL_DIR/" 2>/dev/null || true

if [ -n "$RESOURCES" ]; then
    # Version sanity: warn on skew against the app's bundled core.
    APP_CORE_VERSION="$("$RESOURCES/codex" --version 2>/dev/null || echo unknown)"
    say "App bundled core : $APP_CORE_VERSION"
    say "Patched core     : codex-cli $VERSION"
    case "$APP_CORE_VERSION" in
        *"$VERSION") ;;
        *) say "WARNING: version mismatch. Usually fine, but if the app misbehaves," >&2
           say "         rebuild from the patch on your exact tag (see README)." >&2 ;;
    esac
    ln -sfn "$RESOURCES/codex-code-mode-host" "$INSTALL_DIR/bin/codex-code-mode-host"
    say "Installed core + code-mode-host sibling in $INSTALL_DIR/bin"
else
    say "NOTE: could not locate the desktop app's resources directory."
    say "      The code-mode-host sibling was NOT linked; exec/browser tools will"
    say "      need it — see README ('code-mode host')."
fi

# --- Wire the app to the patched core
if [ "$OS" = "Linux" ]; then
    DESKTOP_SRC=""
    for f in /usr/share/applications/codex-desktop.desktop /usr/share/applications/chatgpt.desktop; do
        [ -f "$f" ] && DESKTOP_SRC="$f" && break
    done
    [ -n "$DESKTOP_SRC" ] || die "no codex-desktop.desktop or chatgpt.desktop found"
    mkdir -p "$HOME/.local/share/applications"
    OUT="$HOME/.local/share/applications/$(basename "$DESKTOP_SRC")"
    awk -v envv="$ENVV" '
        /^Exec=/ && $0 !~ /CODEX_CLI_PATH/ {
            if ($0 ~ /^Exec=env /) sub(/^Exec=env /, "Exec=env " envv " ")
            else sub(/^Exec=/, "Exec=env " envv " ")
        }
        { print }
    ' "$DESKTOP_SRC" > "$OUT"
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$HOME/.local/share/applications" || true
    say "Wrote desktop override: $OUT"
    say ""
    say "Done. Fully QUIT the Codex desktop app and relaunch it, then verify with"
    say "the DELIVERY_OK test in the README."
    say "Uninstall: rm -f '$OUT' && rm -rf '$INSTALL_DIR' && restart the app."
else
    say ""
    say "macOS detected — finish wiring manually (GUI apps need launchctl env):"
    say "  launchctl setenv CODEX_CLI_PATH $INSTALL_DIR/bin/codex"
    say "  launchctl setenv CODEX_MULTI_AGENT_V2_MESSAGE_DELIVERY plaintext"
    say "  launchctl setenv CODEX_MULTI_AGENT_V2_TOOL_NAMESPACE agents"
    say "Then fully quit and relaunch the app. Unset with: launchctl unsetenv <name>."
    say "Place a copy of the app's codex-code-mode-host next to the patched binary."
fi
