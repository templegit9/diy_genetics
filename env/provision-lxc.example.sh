#!/usr/bin/env bash
# =============================================================================
# provision-lxc.example.sh — OPTIONAL helper to create the LXC on a PROXMOX HOST.
#
# This runs on the Proxmox node (NOT inside the container). It is a TEMPLATE:
# copy it, edit the variables, review it, then run it deliberately. Nothing here
# runs automatically — creating containers and touching host storage is your
# call.
#
#   cp env/provision-lxc.example.sh env/provision-lxc.sh
#   $EDITOR env/provision-lxc.sh          # set VMID, storage, resources
#   sudo bash env/provision-lxc.sh
#
# After the container boots, log in and run env/bootstrap-lxc.sh inside it.
# =============================================================================
set -Eeuo pipefail

# ---- EDIT THESE -------------------------------------------------------------
VMID="${VMID:-9001}"                 # unused container ID on your node
HOSTNAME="${HOSTNAME:-diy-genetics}"
STORAGE="${STORAGE:-local-lvm}"      # where the rootfs lives (pvesm status)
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # where CT templates live
BRIDGE="${BRIDGE:-vmbr0}"

# Resources — guide recommends 8+ cores, 32–64 GB RAM, >=1 TB disk per genome.
CORES="${CORES:-8}"
MEMORY_MB="${MEMORY_MB:-32768}"      # 32 GB
SWAP_MB="${SWAP_MB:-8192}"
ROOTFS_GB="${ROOTFS_GB:-1024}"       # 1 TB — alignment temp + refs + outputs

# Debian 12 template. Adjust to a template you have (see: pveam available).
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"

# Unprivileged container is recommended; Apptainer works with the deps that
# bootstrap-lxc.sh installs (uidmap/fuse-overlayfs).
UNPRIVILEGED="${UNPRIVILEGED:-1}"

# Login. Provide an SSH public key path for key-based root login (preferred).
# If empty, the script falls back to prompting for a root password (--password).
# Either way you can always get a shell from the host with: pct enter <VMID>
ROOT_SSH_KEY="${ROOT_SSH_KEY:-}"     # e.g. /root/.ssh/id_ed25519.pub
# =============================================================================

echo "[provision] downloading CT template if missing…"
pveam update || true
if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE}"; then
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
fi

# Choose login method: SSH key if provided, else interactive password prompt.
LOGIN_ARGS=()
if [[ -n "${ROOT_SSH_KEY}" && -f "${ROOT_SSH_KEY}" ]]; then
  LOGIN_ARGS=(--ssh-public-keys "${ROOT_SSH_KEY}")
  echo "[provision] using SSH key ${ROOT_SSH_KEY} for root login"
else
  LOGIN_ARGS=(--password)   # pct will prompt for the root password
  echo "[provision] no ROOT_SSH_KEY set — you will be prompted for a root password"
fi

echo "[provision] creating LXC ${VMID} (${HOSTNAME})…"
pct create "${VMID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY_MB}" \
  --swap "${SWAP_MB}" \
  --rootfs "${STORAGE}:${ROOTFS_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged "${UNPRIVILEGED}" \
  --features "nesting=1" \
  --onboot 0 \
  "${LOGIN_ARGS[@]}"

echo "[provision] starting LXC ${VMID}…"
pct start "${VMID}"

cat <<EOF

[provision] done. Next steps:
  1. Enter the container:      pct enter ${VMID}
  2. Install git + clone this repo (or push it in via 'pct push').
  3. Inside the container:     bash env/bootstrap-lxc.sh

Notes:
  * 'nesting=1' is enabled so Apptainer/DeepVariant can run inside the CT.
  * If you need >1 genome concurrently, bump CORES/MEMORY/ROOTFS accordingly.
  * Consider a separate mountpoint for references/ vs results/ on large arrays.
EOF
