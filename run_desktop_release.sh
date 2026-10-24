#!/usr/bin/env bash
# 🚀 Lanzador de un solo paso para IronLink Desktop (macOS Release)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/frontend/build/macos/Build/Products/Release/IronLink.app"

if [ -d "$APP_PATH" ]; then
  echo "🚀 Abriendo IronLink.app (Versión Release)..."
  open "$APP_PATH"
else
  echo "❌ Error: No se encontró la aplicación en $APP_PATH"
  exit 1
fi
