#!/bin/bash
# KernelSU-Next DKMS installer for Waydroid
# Usage: sudo ./install.sh [--uninstall] [--skip-seccomp] [--kernel <version>]

set -euo pipefail

REPO_URL="https://github.com/Polaricito/KernelSU-Next-Waydroid.git"
BRANCH="waydroid"
SRC_DIR="/usr/src/kernelsu-next"
CLONE_DIR="/tmp/kernelsu-next-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNINSTALL=0
SKIP_SECCOMP=0
TARGET_KERNEL=""

usage() {
    cat <<'EOF'
KernelSU-Next DKMS installer for Waydroid

Usage: sudo ./install.sh [OPTIONS]

Options:
  --uninstall        Remove KernelSU and restore original state
  --skip-seccomp     Do not modify Waydroid seccomp profiles
  --kernel <ver>     Target kernel version (default: uname -r)
  -h, --help         Show this help

Examples:
  sudo ./install.sh                     # Install for running kernel
  sudo ./install.sh --kernel 6.18.42-1-cachyos-lts  # Install for specific kernel
  sudo ./install.sh --uninstall         # Remove everything
EOF
}

log()  { echo "[*] $*"; }
err()  { echo "[!] $*" >&2; }
die()  { err "$@"; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"
}

check_prereqs() {
    local missing=()

    command -v dkms   >/dev/null || missing+=("dkms")
    command -v git    >/dev/null || missing+=("git")
    command -v make   >/dev/null || missing+=("make")
    command -v sed    >/dev/null || missing+=("sed")

    if ! command -v modloader >/dev/null 2>&1; then
        missing+=("modloader (install modloader package)")
    fi

    if [ ! -d "/lib/modules/${TARGET_KERNEL}/build" ]; then
        missing+=("kernel headers for ${TARGET_KERNEL} (install linux-headers-${TARGET_KERNEL})")
    fi

    # Check for LLVM/LLD (required for build)
    if ! command -v ld.lld >/dev/null 2>&1 && ! command -v llvm-ld >/dev/null 2>&1; then
        missing+=("lld (install lld or llvm)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing dependencies:"
        for m in "${missing[@]}"; do
            err "  - $m"
        done
        die "Install the above and retry."
    fi
}

clone_repo() {
    if [ -d "${CLONE_DIR}/.git" ]; then
        log "Updating existing clone at ${CLONE_DIR}..."
        cd "${CLONE_DIR}"
        git fetch --depth 1 origin "${BRANCH}" 2>/dev/null
        git reset --hard FETCH_HEAD
    else
        log "Cloning ${REPO_URL} (branch: ${BRANCH})..."
        rm -rf "${CLONE_DIR}"
        git clone --depth 1 -b "${BRANCH}" "${REPO_URL}" "${CLONE_DIR}"
        cd "${CLONE_DIR}"
    fi

    log "Clone at commit: $(git rev-parse --short HEAD)"
}

compute_version() {
    cd "${CLONE_DIR}"
    KSU_COUNT=$(git rev-list --count HEAD)
    KSU_HASH=$(git rev-parse --short HEAD)
    KSU_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v${KSU_COUNT}")
    PKGVER="0.${KSU_COUNT}.g${KSU_HASH}"

    log "Version: ${PKGVER} (count=${KSU_COUNT}, tag=${KSU_TAG})"
}

install_sources() {
    local INSTALL_DIR="${SRC_DIR}-${PKGVER}"
    log "Installing kernel sources to ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"

    cp -r "${CLONE_DIR}/kernel/"* "${INSTALL_DIR}/"
    cp -r "${CLONE_DIR}/uapi/"* "${INSTALL_DIR}/" 2>/dev/null || true
    install -Dm644 "${SCRIPT_DIR}/Makefile" "${INSTALL_DIR}/Makefile"

    sed "s|@PKGVER@|${PKGVER}|g;
         s|@KSU_GIT_VERSION@|${KSU_COUNT}|g;
         s|@KSU_GIT_TAG@|${KSU_TAG}|g;" \
        "${SCRIPT_DIR}/dkms.conf" > "${INSTALL_DIR}/dkms.conf"
}

build_dkms() {
    log "Building DKMS module..."
    dkms remove "${PKGVER}" -k "${TARGET_KERNEL}" 2>/dev/null || true

    bash -c "LLVM=1 dkms build kernelsu-next/${PKGVER} -k ${TARGET_KERNEL}" 2>&1 | tail -5
    log "Build complete."
}

install_dkms() {
    log "Installing DKMS module..."
    dkms install "kernelsu-next/${PKGVER}" -k "${TARGET_KERNEL}" 2>&1 | tail -3
    log "Module installed."
}

install_helpers() {
    log "Installing load-kernelsu and modprobe alias..."
    install -Dm755 "${SCRIPT_DIR}/load-kernelsu.in" /usr/bin/load-kernelsu
    install -Dm644 "${SCRIPT_DIR}/00-kernelsu.conf" /etc/modprobe.d/00-kernelsu.conf
    log "Helpers installed."
}

install_services() {
    log "Installing systemd services..."
    install -Dm644 "${SCRIPT_DIR}/kernelsu-autload.service" /etc/systemd/system/kernelsu-autload.service
    install -Dm755 "${SCRIPT_DIR}/kernelsu-stage.sh" /usr/local/sbin/kernelsu-stage.sh
    systemctl daemon-reload
    systemctl enable kernelsu-autload.service 2>/dev/null || true
    systemctl start kernelsu-stage.service 2>/dev/null || true
    log "Services installed and enabled."
}

fix_seccomp() {
    if [ "${SKIP_SECCOMP}" -eq 1 ]; then
        log "Skipping seccomp fix (--skip-seccomp)."
        return
    fi

    log "Fixing Waydroid seccomp profiles (removing reboot block)..."
    local fixed=0

    for f in /usr/lib/waydroid/data/configs/waydroid.seccomp \
             /var/lib/waydroid/lxc/waydroid/waydroid.seccomp; do
        if [ -f "$f" ] && grep -q '^reboot$' "$f"; then
            sed -i '/^reboot$/d' "$f"
            fixed=1
        fi
    done

    if [ "${fixed}" -eq 1 ]; then
        log "Seccomp fixed. Restarting waydroid-container..."
        systemctl restart waydroid-container.service 2>/dev/null || true
    else
        log "Seccomp profiles already clean or not found."
    fi
}

load_module() {
    log "Loading kernel module..."
    if lsmod | grep -q kernelsu; then
        log "Module already loaded, reloading..."
        /usr/bin/load-kernelsu --unload-first 2>/dev/null || rmmod kernelsu 2>/dev/null || true
    fi
    /usr/bin/load-kernelsu
    log "Module loaded."
    lsmod | grep kernelsu
}

stage_ksud() {
    log "Staging ksud into container..."
    /usr/local/sbin/kernelsu-stage.sh 2>/dev/null || log "ksud staging skipped (binary not found)."
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    log "Uninstalling KernelSU-Next DKMS..."

    # Unload module
    if lsmod | grep -q kernelsu; then
        log "Unloading module..."
        rmmod kernelsu 2>/dev/null || true
    fi

    # Remove from DKMS (all kernel versions)
    log "Removing from DKMS..."
    dkms status 2>/dev/null | grep kernelsu | while IFS=', ' read -r modver kver archstatus; do
        [ -n "${modver}" ] && dkms remove "${modver}" -k "${kver}" 2>/dev/null || true
    done

    # Remove installed files
    log "Removing installed files..."
    rm -rf "${SRC_DIR}"-*
    rm -f /usr/bin/load-kernelsu
    rm -f /etc/modprobe.d/00-kernelsu.conf
    rm -f /etc/systemd/system/kernelsu-autload.service
    rm -f /usr/local/sbin/kernelsu-stage.sh
    systemctl daemon-reload 2>/dev/null || true

    log "Uninstall complete. Optionally revert seccomp fix with:"
    log "  sudo systemctl restart waydroid-container.service"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    while [ $# -gt 0 ]; do
        case $1 in
            --uninstall)    UNINSTALL=1 ;;
            --skip-seccomp) SKIP_SECCOMP=1 ;;
            --kernel)       shift; TARGET_KERNEL="${1:-}" ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1" ;;
        esac
        shift
    done

    [ -z "${TARGET_KERNEL}" ] && TARGET_KERNEL=$(uname -r)

    need_root "$@"

    if [ "${UNINSTALL}" -eq 1 ]; then
        do_uninstall
        exit 0
    fi

    check_prereqs
    clone_repo
    compute_version
    install_sources
    build_dkms
    install_dkms
    install_helpers
    install_services
    fix_seccomp
    load_module
    stage_ksud

    echo ""
    log "=== KernelSU-Next installed successfully ==="
    log "Kernel version: ${TARGET_KERNEL}"
    log "KSU_VERSION:    $((30000 + KSU_COUNT))"
    log "Tag:            ${KSU_TAG}"
    log ""
    log "Start Waydroid session: waydroid session start"
    log "Install the Manager app: com.rifsxd.ksunext"
}

main "$@"
