#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers sourced by every pipeline stage.
#
# Provides: strict-mode setup, config loading, timestamped logging, tool
# preflight (`require`), a resumability guard (`skip_if_done`), download +
# checksum helpers, and DRY_RUN-aware command execution (`run`).
#
# Usage from a stage script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =============================================================================

# ---- strict mode ------------------------------------------------------------
set -Eeuo pipefail

# ---- resolve paths & load config -------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
export PROJECT_ROOT

CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/pipeline.conf}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
else
  echo "FATAL: config not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# DRY_RUN is honored by run()/download(). Orchestrator exports it; default off.
DRY_RUN="${DRY_RUN:-0}"

# ---- logging ----------------------------------------------------------------
# Colored when attached to a TTY, plain otherwise (so log files stay clean).
if [[ -t 2 ]]; then
  _C_RESET=$'\033[0m'; _C_BLUE=$'\033[34m'; _C_YEL=$'\033[33m'
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_DIM=$'\033[2m'
else
  _C_RESET=""; _C_BLUE=""; _C_YEL=""; _C_RED=""; _C_GRN=""; _C_DIM=""
fi

_ts() { date +"%Y-%m-%d %H:%M:%S"; }
log()      { echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_BLUE}[INFO]${_C_RESET}  $*" >&2; }
log_ok()   { echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_GRN}[ OK ]${_C_RESET}  $*" >&2; }
log_warn() { echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[WARN]${_C_RESET}  $*" >&2; }
log_err()  { echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_RED}[FAIL]${_C_RESET}  $*" >&2; }
die()      { log_err "$*"; exit 1; }

# Error trap: report the failing command + line for easier debugging.
_on_err() {
  local ec=$? line=${1:-?}
  log_err "command failed (exit ${ec}) at ${BASH_SOURCE[1]:-?}:${line}: ${BASH_COMMAND}"
  exit "${ec}"
}
trap '_on_err ${LINENO}' ERR

# ---- preflight --------------------------------------------------------------
# require cmd1 cmd2 ... — die unless every command is on PATH.
# Under DRY_RUN the check is advisory (warn, don't abort) so the plan prints
# even on a machine without the toolchain installed.
require() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      if [[ "${DRY_RUN}" == "1" ]]; then
        log_warn "would require tool (not installed): ${c}"
      else
        log_err "missing required tool: ${c}"
        missing=1
      fi
    fi
  done
  (( missing == 0 )) || die "install missing tools first (see env/bootstrap-lxc.sh)"
}

# require_file path [description] — die unless a file exists and is non-empty.
# Advisory under DRY_RUN (inputs may not exist yet when only planning).
require_file() {
  local f="$1" desc="${2:-file}"
  [[ -s "${f}" ]] && return 0
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "would require ${desc} (missing): ${f}"
    return 0
  fi
  die "${desc} not found or empty: ${f}"
}

# ---- command execution (DRY_RUN aware) -------------------------------------
# run <cmd...> — echo the command; execute it unless DRY_RUN=1.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[DRY ]${_C_RESET}  $*" >&2
    return 0
  fi
  log "\$ $*"
  "$@"
}

# ---- resumability -----------------------------------------------------------
# skip_if_done <output> [more_outputs...]
#   Returns 0 (success) if EVERY listed output already exists & is non-empty,
#   logging that the stage is being skipped. Returns 1 otherwise.
# Pattern in a stage:
#   if skip_if_done "$OUT"; then exit 0; fi
skip_if_done() {
  local o
  for o in "$@"; do
    [[ -s "${o}" ]] || return 1
  done
  log_ok "up-to-date, skipping (exists: $*)"
  return 0
}

# ensure_dir <dir...> — mkdir -p, honoring DRY_RUN.
ensure_dir() {
  local d
  for d in "$@"; do
    [[ -d "${d}" ]] || run mkdir -p "${d}"
  done
}

# ---- downloads & checksums --------------------------------------------------
# download <url> <dest> — resumable download (curl -C -), skips if dest exists.
download() {
  local url="$1" dest="$2"
  if [[ -s "${dest}" ]]; then
    log_ok "already downloaded: ${dest##*/}"
    return 0
  fi
  ensure_dir "$(dirname "${dest}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${_C_DIM}$(_ts)${_C_RESET} ${_C_YEL}[DRY ]${_C_RESET}  download ${url} -> ${dest}" >&2
    return 0
  fi
  log "downloading ${url}"
  # -f fail on HTTP error, -L follow redirects, -C - resume, -o atomic-ish tmp
  curl -fL -C - --retry 3 --retry-delay 5 -o "${dest}.part" "${url}"
  mv "${dest}.part" "${dest}"
  log_ok "downloaded ${dest##*/}"
}

# verify_md5 <file> <expected_md5> — die on mismatch; warn+skip if no md5 tool.
verify_md5() {
  local file="$1" expected="$2" actual tool
  [[ "${DRY_RUN}" == "1" ]] && return 0
  require_file "${file}"
  if command -v md5sum >/dev/null 2>&1; then
    actual="$(md5sum "${file}" | awk '{print $1}')"
  elif command -v md5 >/dev/null 2>&1; then
    actual="$(md5 -q "${file}")"
  else
    log_warn "no md5 tool available; skipping checksum for ${file##*/}"
    return 0
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    die "checksum mismatch for ${file}: expected ${expected}, got ${actual}"
  fi
  log_ok "checksum verified: ${file##*/}"
}

# ---- misc -------------------------------------------------------------------
# stage_banner <name> — pretty header at the top of a stage.
stage_banner() {
  log "──────────────────────────────────────────────────────────"
  log "Stage: $* ${_C_DIM}(sample=${SAMPLE}, caller=${CALLER})${_C_RESET}"
  log "──────────────────────────────────────────────────────────"
}
