#!/usr/bin/env bash
# =============================================================================
# run-webui.sh — launch the DIY Genetics control-panel API (FastAPI/uvicorn).
#
# Serves the web UI + pipeline control endpoints. Bind to a trusted network
# only (it shells out to the pipeline). Set DIY_WEBUI_TOKEN to require a token.
#
#   bash webui/run-webui.sh                 # 0.0.0.0:8080
#   HOST=127.0.0.1 PORT=9000 bash webui/run-webui.sh
# =============================================================================
set -Eeuo pipefail

WEBUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

# Prefer the conda env's uvicorn if present; fall back to whatever's on PATH.
if ! command -v uvicorn >/dev/null 2>&1; then
  echo "uvicorn not found. Activate the env first:  conda activate diy-genetics" >&2
  echo "(or install: mamba env update -f env/environment.yml)" >&2
  exit 1
fi

echo "[webui] serving control panel on http://${HOST}:${PORT}"
[[ -n "${DIY_WEBUI_TOKEN:-}" ]] && echo "[webui] auth token required (DIY_WEBUI_TOKEN set)"

# app.py lives in WEBUI_DIR; run uvicorn with that as the working dir so the
# module import 'app:app' and static/ path resolve.
cd "${WEBUI_DIR}"
exec uvicorn app:app --host "${HOST}" --port "${PORT}"
