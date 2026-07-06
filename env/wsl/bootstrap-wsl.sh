#!/usr/bin/env bash
# =============================================================================
# bootstrap-wsl.sh — provision the pipeline toolchain INSIDE a WSL2 Ubuntu
# distro on the RTX workstation. Idempotent; safe to re-run.
#
# Installs: build deps, native Docker Engine + NVIDIA Container Toolkit (so
# `docker run --gpus all` works for Parabricks — Docker Desktop integration is
# NOT required), Miniforge + the `diy-genetics` conda env.
#
# Run from the repo root inside WSL:
#   bash env/wsl/bootstrap-wsl.sh            # full setup
#   bash env/wsl/bootstrap-wsl.sh --gpu-test # also run a docker GPU smoke test
#   bash env/wsl/bootstrap-wsl.sh --parabricks-pull  # also pull Parabricks (~15GB, needs NGC login)
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/env/environment.yml"

DO_GPU_TEST=0
DO_PB_PULL=0
for arg in "$@"; do
  case "${arg}" in
    --gpu-test) DO_GPU_TEST=1 ;;
    --parabricks-pull) DO_PB_PULL=1 ;;
    *) echo "unknown arg: ${arg}" >&2; exit 2 ;;
  esac
done

log()  { echo -e "\033[34m[wsl-bootstrap]\033[0m $*"; }
warn() { echo -e "\033[33m[wsl-bootstrap]\033[0m $*"; }
die()  { echo -e "\033[31m[wsl-bootstrap]\033[0m $*" >&2; exit 1; }

if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

# --- sanity: are we actually in WSL? ----------------------------------------
if ! grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  warn "this doesn't look like WSL (/proc/version). Continuing anyway."
fi

# --- config-derived values (Parabricks image tag) ---------------------------
# shellcheck disable=SC1091
[[ -f "${REPO_ROOT}/config/pipeline.conf" ]] && source "${REPO_ROOT}/config/pipeline.conf"
PARABRICKS_IMAGE="${PARABRICKS_IMAGE:-nvcr.io/nvidia/clara/clara-parabricks:4.4.0-1}"

# --- 1. base system packages ------------------------------------------------
log "installing base packages…"
export DEBIAN_FRONTEND=noninteractive
${SUDO} apt-get update -qq
${SUDO} apt-get install -y --no-install-recommends \
  build-essential curl wget git ca-certificates gnupg bzip2 lsb-release

# --- 2. Docker Engine (native, from Docker's apt repo) ----------------------
# Guard on `dockerd`, NOT `docker`: Docker Desktop puts a Windows `docker` shim
# (/mnt/c/Program Files/Docker/...) on the WSL PATH, which would fool a
# `command -v docker` check into skipping the real native install. Only a real
# docker-ce install provides the `dockerd` daemon.
if ! command -v dockerd >/dev/null 2>&1; then
  log "installing native Docker Engine (Docker Desktop shim is not a real daemon)…"
  . /etc/os-release
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  ${SUDO} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
  ${SUDO} apt-get update -qq
  ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  # let the current user run docker without sudo (takes effect on next login)
  ${SUDO} usermod -aG docker "$(id -un)" || true
else
  log "native Docker Engine already installed ($(dockerd --version 2>/dev/null | head -1))"
fi

# Use the REAL docker binary explicitly so the Docker Desktop PATH shim can't
# shadow it for daemon checks / GPU tests.
DOCKER_BIN=/usr/bin/docker
command -v "${DOCKER_BIN}" >/dev/null 2>&1 || DOCKER_BIN=docker

# --- 3. NVIDIA Container Toolkit (GPU inside containers) ---------------------
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "installing NVIDIA Container Toolkit…"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | ${SUDO} tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  ${SUDO} apt-get update -qq
  ${SUDO} apt-get install -y nvidia-container-toolkit
  ${SUDO} nvidia-ctk runtime configure --runtime=docker
else
  log "NVIDIA Container Toolkit already installed"
  ${SUDO} nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
fi

# --- 4. start the Docker daemon (systemd if present, else dockerd) -----------
start_docker() {
  if [[ -d /run/systemd/system ]]; then
    ${SUDO} systemctl enable --now docker
  else
    warn "systemd not active in this distro — starting dockerd in the background."
    warn "For a persistent daemon, enable systemd (setup-wsl.ps1 does this) and re-run."
    if ! ${SUDO} service docker start 2>/dev/null; then
      ${SUDO} sh -c 'nohup dockerd >/var/log/dockerd.log 2>&1 &' || true
    fi
  fi
  # wait for the socket
  for _ in $(seq 1 20); do
    ${SUDO} "${DOCKER_BIN}" info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
log "starting Docker daemon…"
start_docker && log "Docker daemon is up" || warn "Docker daemon not confirmed up — check logs."

# --- 5. Miniforge + conda env -----------------------------------------------
CONDA_DIR="${HOME}/miniforge3"
if [[ ! -x "${CONDA_DIR}/bin/conda" ]]; then
  log "installing Miniforge…"
  arch="$(uname -m)"
  curl -fsSL -o "/tmp/Miniforge3.sh" \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
  bash "/tmp/Miniforge3.sh" -b -p "${CONDA_DIR}"
  rm -f "/tmp/Miniforge3.sh"
else
  log "Miniforge already present"
fi
# shellcheck disable=SC1091
source "${CONDA_DIR}/etc/profile.d/conda.sh"
"${CONDA_DIR}/bin/conda" init bash >/dev/null 2>&1 || true

if conda env list | awk '{print $1}' | grep -qx "diy-genetics"; then
  log "updating conda env 'diy-genetics'…"
  mamba env update -f "${ENV_FILE}" --prune
else
  log "creating conda env 'diy-genetics'…"
  mamba env create -f "${ENV_FILE}"
fi

# --- 6. optional: GPU smoke test through Docker ------------------------------
if [[ "${DO_GPU_TEST}" == "1" ]]; then
  log "GPU smoke test: docker run --gpus all ubuntu nvidia-smi…"
  if ${SUDO} "${DOCKER_BIN}" run --rm --gpus all ubuntu nvidia-smi -L; then
    log "✓ GPU is visible inside Docker containers"
  else
    warn "GPU test failed — check driver / nvidia-container-toolkit / systemd."
  fi
fi

# --- 7. optional: pull Parabricks (large; needs NGC login) ------------------
if [[ "${DO_PB_PULL}" == "1" ]]; then
  log "pulling Parabricks image ${PARABRICKS_IMAGE} (~15 GB)…"
  if ! ${SUDO} "${DOCKER_BIN}" pull "${PARABRICKS_IMAGE}"; then
    warn "pull failed. Log in to NGC first:"
    warn "  docker login nvcr.io   (username: \$oauthtoken, password: your NGC API key)"
    warn "Get a free key at https://ngc.nvidia.com > Setup > API Key."
  fi
fi

log "done. Next: 'conda activate diy-genetics', then run the pipeline."
log "Verify tools: bwa-mem2 version; gatk --version; docker run --rm --gpus all ubuntu nvidia-smi"
