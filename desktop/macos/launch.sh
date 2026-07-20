#!/bin/bash
set -euo pipefail

# Fast incremental dev launch for the omi-rewind-policy named bundle.
# This mirrors desktop-ui-rework/launch.sh but also bundles the desktop-core
# Rust dylib (libomi_desktop_core.dylib) that playground/undivisible links.

cd "$(dirname "$0")"

APP_NAME="omi-rewind-policy"
BUILD_DIR="Desktop/.build"
APP_BUNDLE="build/$APP_NAME.app"
BIN="$APP_BUNDLE/Contents/MacOS/Omi Computer"
RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle"

echo "[launch] Building Swift app..."
xcrun swift build -c debug --package-path Desktop

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "[launch] Copying binary..."
cp -f "$BUILD_DIR/debug/Omi Computer" "$BIN"

echo "[launch] Copying frameworks..."
for fw in Sparkle Sentry onnxruntime; do
  if [ -d "$BUILD_DIR/debug/$fw.framework" ]; then
    cp -Rf "$BUILD_DIR/debug/$fw.framework" "$APP_BUNDLE/Contents/Frameworks/"
  fi
done

# Bundle and rewrite libomi_desktop_core.dylib load path.
DYLIB_NAME="libomi_desktop_core.dylib"
DYLIB_SRC="../target/debug/deps/$DYLIB_NAME"
if [ -f "$DYLIB_SRC" ]; then
  echo "[launch] Bundling $DYLIB_NAME..."
  cp -f "$DYLIB_SRC" "$APP_BUNDLE/Contents/Frameworks/$DYLIB_NAME"
  install_name_tool -id "@rpath/$DYLIB_NAME" "$APP_BUNDLE/Contents/Frameworks/$DYLIB_NAME" 2>/dev/null || true
  current_path="$(otool -L "$BIN" | awk -v name="$DYLIB_NAME" 'NF>0 && $0 ~ name { print $1; exit }')"
  if [ -n "$current_path" ] && [ "$current_path" != "@rpath/$DYLIB_NAME" ]; then
    install_name_tool -change "$current_path" "@rpath/$DYLIB_NAME" "$BIN" 2>/dev/null || true
  fi
fi

# Ensure the binary searches bundled frameworks/dylibs.
if ! otool -l "$BIN" | grep -q 'executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
fi

# Copy the SwiftPM resource bundle (images, node binary, etc.).
echo "[launch] Copying resource bundle..."
rm -rf "$RESOURCE_BUNDLE"
cp -Rf "$BUILD_DIR/out/Products/Debug/Omi Computer_Omi Computer.bundle" "$APP_BUNDLE/Contents/Resources/"

# Stage the Node agent runtime.
if [ -d "agent/dist" ] && [ -d ".harness/agent-runtime/agent-node_modules" ]; then
  echo "[launch] Staging agent runtime..."
  rm -rf "$APP_BUNDLE/Contents/Resources/agent"
  mkdir -p "$APP_BUNDLE/Contents/Resources/agent/src/runtime"
  cp -Rf "agent/dist" "$APP_BUNDLE/Contents/Resources/agent/"
  cp -f "agent/package.json" "$APP_BUNDLE/Contents/Resources/agent/"
  cp -Rf ".harness/agent-runtime/agent-node_modules" "$APP_BUNDLE/Contents/Resources/agent/node_modules"
  for src in agent/src/runtime/control-tool-manifest.ts agent/src/runtime/node-tools.ts agent/src/runtime/omi-tool-manifest.ts; do
    [ -f "$src" ] && cp -f "$src" "$APP_BUNDLE/Contents/Resources/agent/src/runtime/" || true
  done
fi

# Stage pi-mono-extension.
if [ -d ".harness/agent-runtime/pi-mono-extension-node_modules" ]; then
  echo "[launch] Staging pi-mono-extension..."
  rm -rf "$APP_BUNDLE/Contents/Resources/pi-mono-extension"
  mkdir -p "$APP_BUNDLE/Contents/Resources/pi-mono-extension"
  for src in pi-mono-extension/index.ts pi-mono-extension/package.json pi-mono-extension/package-lock.json; do
    [ -f "$src" ] && cp -f "$src" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/" || true
  done
  cp -Rf ".harness/agent-runtime/pi-mono-extension-node_modules" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/node_modules"
fi

# Copy the Rust agent runtime binary if it exists.
if [ -f "../target/debug/omi-agent-runtime" ]; then
  cp -f "../target/debug/omi-agent-runtime" "$RESOURCE_BUNDLE/omi-agent-runtime"
  chmod +x "$RESOURCE_BUNDLE/omi-agent-runtime"
fi

echo "[launch] Signing..."
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "[launch] Killing existing $APP_NAME instances..."
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 1

echo "[launch] Launching $APP_NAME..."
"$BIN" &
