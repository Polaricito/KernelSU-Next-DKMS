#!/bin/bash
# KernelSU-Next one-line uninstaller entry point.
#
#   curl -fsSL https://raw.githubusercontent.com/Polaricito/KernelSU-Next-DKMS/master/uninstaller.sh | sudo bash
#
# It clones the KernelSU-Next-DKMS repo and defers to the real uninstall
# routine (install.sh --uninstall), which removes the DKMS modules, unloads
# the module, and deletes all installed files and services.

set -euo pipefail

REPO_URL="https://github.com/Polaricito/KernelSU-Next-DKMS.git"
BRANCH="master"
WORK_DIR="/tmp/kernelsu-dkms-uninstall"

log() { echo "[*] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL <url> | sudo bash"
    command -v git >/dev/null || die "git is required"
}

clone_repo() {
    if [ -d "${WORK_DIR}/.git" ]; then
        log "Updating existing clone at ${WORK_DIR}..."
        cd "${WORK_DIR}"
        git fetch --depth 1 origin "${BRANCH}" 2>/dev/null
        git reset --hard FETCH_HEAD
    else
        log "Cloning ${REPO_URL} (branch: ${BRANCH})..."
        rm -rf "${WORK_DIR}"
        git clone --depth 1 -b "${BRANCH}" "${REPO_URL}" "${WORK_DIR}"
    fi
}

main() {
    need_root "$@"
    clone_repo

    chmod +x "${WORK_DIR}/install.sh"
    echo ""
    log "Starting KernelSU-Next uninstaller..."
    exec "${WORK_DIR}/install.sh" --uninstall
}

main "$@"