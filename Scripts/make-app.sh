#!/bin/bash
# Assembles Prose.app around the SwiftPM binary.
#
# SwiftPM cannot produce an app bundle, and an unbundled executable is not just
# cosmetically wrong: WKWebView will not start its web content process without a
# bundle identifier, so the browser pane (plan §2) renders nothing at all. The
# window chrome also needs the activation policy set by hand without one.
#
#   ./Scripts/make-app.sh [debug|release]   →   .build/Prose.app
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Prose.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/prose"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/prose"

# The agents travel with the app. `AgentProcess` already looks in Resources for
# them and nothing put them there, so that path was dead: a bundle moved off
# this machine fell through to walking up towards a source checkout, found
# none, and opened every pane on `agent exited (code 2)`. The whole directory
# goes, not just the scripts — each agent imports `prose_agent` beside it, and
# the bundled skills live in `agents/skills`.
#
# `.venv` is excluded, and that is a real limitation rather than tidiness. It
# is several hundred megabytes (the SDK bundles a native Claude Code binary),
# its `bin/python3` is a symlink into a framework that will not exist on
# another machine, and its `pyvenv.cfg` holds an absolute home path. So the
# bundle carries the scripts and no interpreter: on this machine
# `AgentProcess.interpreter` walks up and finds the checkout's venv, and a
# bundle moved elsewhere needs `Scripts/setup-agents.sh` run there. Making the
# bundle relocatable is a distribution question, and it belongs with plan §11's
# notarisation decision rather than here.
rm -rf "$APP/Contents/Resources/agents"
rsync -a --exclude '.venv' --exclude '__pycache__' --exclude '*.egg-info' \
    "$ROOT/agents/" "$APP/Contents/Resources/agents/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Prose</string>
    <key>CFBundleDisplayName</key><string>Prose</string>
    <key>CFBundleExecutable</key><string>prose</string>
    <!-- spec §2's app id. -->
    <key>CFBundleIdentifier</key><string>prose</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- spec §2: exactly one window, and no restoration of it. -->
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "built $APP"
