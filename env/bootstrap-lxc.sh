#!/usr/bin/env bash
# =============================================================================
# bootstrap-lxc.sh — one-time toolchain setup INSIDE a fresh Debian/Ubuntu LXC.
#
# Idempotent: safe to re-run. Installs system deps, Miniforge (conda+mamba),
# the `diy-genetics` conda env, Apptainer, and pre-pulls the DeepVariant image.
#
# Run as a normal user with sudo available:
#   bash env/bootstrap-lxc.sh
# Then:
#   conda activate diy-genetics
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/env/environment.yml"

# Config-derived values (for pre-pulling the right DeepVariant image).
# shellcheck disable=SC1091
[[ -f "${REPO_ROOT}/config/pipeline.conf" ]] && source "${REPO_ROOT}/config/pipeline.conf"
DV_VERSION="${DV_VERSION:-1.6.1}"
SIF_DIR="${REF_DIR:-${REPO_ROOT}/references}/containers"

log()  { echo -e "\033[34m[bootstrap]\033[0m $*"; }
warn() { echo -e "\033[33m[bootstrap]\033[0m $*"; }

# --- sudo helper (works whether or not we're already root) -------------------
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# --- 1. system packages ------------------------------------------------------
log "installing system packages (apt)…"
export DEBIAN_FRONTEND=noninteractive
${SUDO} apt-get update -qq
${SUDO} apt-get install -y --no-install-recommends \
  build-essential curl wget git ca-certificates bzip2 \
  uidmap fuse-overlayfs squashfs-tools \
  libgomp1

# --- 2. Miniforge (conda + mamba) -------------------------------------------
CONDA_DIR="${HOME}/miniforge3"
if [[ ! -x "${CONDA_DIR}/bin/conda" ]]; then
  log "installing Miniforge to ${CONDA_DIR}…"
  arch="$(uname -m)"
  installer="Miniforge3-Linux-${arch}.sh"
  curl -fsSL -o "/tmp/${installer}" \
    "https://github.com/conda-forge/miniforge/releases/latest/download/${installer}"
  bash "/tmp/${installer}" -b -p "${CONDA_DIR}"
  rm -f "/tmp/${installer}"
else
  log "Miniforge already present at ${CONDA_DIR}"
fi

# shellcheck disable=SC1091
source "${CONDA_DIR}/etc/profile.d/conda.sh"
# Initialize shell integration once (idempotent — conda guards duplicates).
"${CONDA_DIR}/bin/conda" init bash >/dev/null 2>&1 || true

# --- 3. conda env from environment.yml --------------------------------------
if conda env list | awk '{print $1}' | grep -qx "diy-genetics"; then
  log "updating existing 'diy-genetics' env…"
  mamba env update -f "${ENV_FILE}" --prune
else
  log "creating 'diy-genetics' env (this pulls a lot of packages)…"
  mamba env create -f "${ENV_FILE}"
fi

# --- 4. Apptainer (for DeepVariant) -----------------------------------------
if ! command -v apptainer >/dev/null 2>&1; then
  log "installing Apptainer…"
  # Prefer the distro package; fall back to the official .deb if unavailable.
  if ${SUDO} apt-get install -y apptainer 2>/dev/null; then
    log "Apptainer installed from apt"
  else
    warn "apt has no 'apptainer' package; installing from GitHub release .deb"
    ver="1.3.4"; arch="$(dpkg --print-architecture)"
    deb="apptainer_${ver}_${arch}.deb"
    curl -fsSL -o "/tmp/${deb}" \
      "https://github.com/apptainer/apptainer/releases/download/v${ver}/${deb}"
    ${SUDO} apt-get install -y "/tmp/${deb}"
    rm -f "/tmp/${deb}"
  fi
else
  log "Apptainer already installed: $(apptainer --version)"
fi

# --- 5. pre-pull DeepVariant image ------------------------------------------
mkdir -p "${SIF_DIR}"
DV_SIF="${SIF_DIR}/deepvariant_${DV_VERSION}.sif"
if [[ -s "${DV_SIF}" ]]; then
  log "DeepVariant image already cached: ${DV_SIF}"
else
  log "pulling DeepVariant ${DV_VERSION} image (large, one-time)…"
  apptainer pull "${DV_SIF}" "docker://google/deepvariant:${DV_VERSION}" \
    || warn "DeepVariant pull failed — only needed if CALLER=deepvariant. Retry later."
fi

log "done. Activate the env with:  conda activate diy-genetics"
log "Verify tools:  bwa-mem2 version; samtools --version; gatk --version"
