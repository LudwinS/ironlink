#!/usr/bin/env bash
# 🚀 Lanzador de un solo paso para IronLink Web (Release)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP=$(ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
PORT=3000

echo "================================================="
echo "  🚀 IronLink Web — Modo Release"
echo "  Acceso local / externo: http://$IP:$PORT"
echo "  API Backend vinculada:  http://$IP:8080"
echo "================================================="

cd "$SCRIPT_DIR/frontend"
exec python3 -m http.server "$PORT" --directory build/web --bind 0.0.0.0
