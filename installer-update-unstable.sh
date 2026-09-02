#!/bin/bash
# KernelSU-Next UNSTABLE updater for Waydroid
#
# EXPERIMENTAL: tracks the latest upstream KernelSU-Next `dev` branch directly
# and re-applies the Waydroid adaptation commits on top, then rebuilds the
# DKMS module.
#
# Use only if you need bleeding-edge changes before a proper stable release.
# This can break; if a patch fails to apply cleanly the script stops safely
# and leaves the current working module untouched.
#
# Usage: sudo ./installer-update-unstable.sh [--skip-seccomp] [--kernel <ver>]

set -euo pipefail

UPSTREAM_URL="https://github.com/KernelSU-Next/KernelSU-Next.git"
FORK_URL="https://github.com/Polaricito/KernelSU-Next-Waydroid.git"
FORK_BRANCH="waydroid"
UPSTREAM_BRANCH="dev"

SRC_DIR="/usr/src/kernelsu-next"
FORK_DIR="/tmp/kernelsu-next-fork"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SKIP_SECCOMP=0
TARGET_KERNEL=""

log()  { echo "[*] $*"; }
err()  { echo "[!] $*" >&2; }
die()  { err "$@"; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"
}

check_prereqs() {
    local missing=()
    command -v dkms >/dev/null     || missing+=("dkms")
    command -v git  >/dev/null     || missing+=("git")
    command -v make >/dev/null     || missing+=("make")
    command -v sed  >/dev/null     || missing+=("sed")
    if ! command -v modloader >/dev/null 2>&1; then
        missing+=("modloader (install modloader package)")
    fi
    if ! command -v ld.lld >/dev/null 2>&1 && ! command -v llvm-ld >/dev/null 2>&1; then
        missing+=("lld (install lld or llvm)")
    fi
    if [ ! -d "/lib/modules/${TARGET_KERNEL}/build" ]; then
        missing+=("kernel headers for ${TARGET_KERNEL} (install linux-headers-${TARGET_KERNEL})")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing dependencies:"
        for m in "${missing[@]}"; do
            err "  - $m"
        done
        die "Install the above and retry."
    fi
}

clone_fork() {
    log "Cloning Waydroid fork '${FORK_BRANCH}' (for adaptation patches)..."
    rm -rf "${FORK_DIR}"
    git clone --depth 1 -b "${FORK_BRANCH}" "${FORK_URL}" "${FORK_DIR}"
    cd "${FORK_DIR}"
    log "Unshallowing fork for full history..."
    git fetch --unshallow origin "${FORK_BRANCH}" 2>/dev/null || true
    git fetch --tags origin "${FORK_BRANCH}" 2>/dev/null || true
}

# Rebuild "upstream dev + waydroid patches" inside the fork clone (full history).
# Resulting tree is left in ${FORK_DIR}; we then build from it.
apply_waydroid_patches() {
    cd "${FORK_DIR}"
    git checkout "${FORK_BRANCH}" 2>/dev/null || true

    log "Fetching upstream '${UPSTREAM_BRANCH}' history (for merge-base)..."
    git fetch --deepen=100000 "${UPSTREAM_URL}" "${UPSTREAM_BRANCH}" 2>/dev/null || true
    local upstream_ref="FETCH_HEAD"

    local mb
    mb=$(git merge-base "${FORK_BRANCH}" "${upstream_ref}")
    [ -n "$mb" ] || die "Could not find merge-base between fork and upstream"

    mapfile -t PATCHES < <(git rev-list --reverse "${mb}".."${FORK_BRANCH}")
    if [ ${#PATCHES[@]} -eq 0 ]; then
        log "No fork-only patches to apply (fork is behind/equal to upstream)."
        return
    fi
    log "Applying ${#PATCHES[@]} Waydroid adaptation patches onto latest upstream dev..."

    # Move working tree to latest upstream dev (detached), keep patch objects.
    git reset --hard "${upstream_ref}" 2>/dev/null

    for c in "${PATCHES[@]}"; do
        if ! git cherry-pick --no-commit "$c" 2>/tmp/kernelsu-pick.err; then
            git cherry-pick --abort 2>/dev/null || true
            git reset --hard "${upstream_ref}" 2>/dev/null || true
            echo ""
            err "=== UNSTABLE UPDATE ABORTED ==="
            err "Patch $(git log -1 --oneline "$c") did not apply onto latest upstream '${UPSTREAM_BRANCH}'."
            err "The upstream dev branch changed interfaces this patch touches."
            err "Your currently installed (stable) module was NOT modified."
            err "Consider waiting for the curated Waydroid fork to catch up."
            die "Aborted: cherry-pick conflict"
        fi
    done
    git commit -m "unstable: rebased upstream dev + waydroid patches" >/dev/null 2>&1 || true
    log "Rebased tree ready at ${FORK_DIR}"
}

compute_version() {
    cd "${FORK_DIR}"
    KSU_COUNT=$(git rev-list --count HEAD)
    KSU_HASH=$(git rev-parse --short HEAD)
    # dev track: no v3.3.0-style semver; use a dev-style tag
    KSU_TAG="unstable-dev-${KSU_COUNT}"
    PKGVER="0.${KSU_COUNT}.g${KSU_HASH}"

    log "Version: ${PKGVER} (count=${KSU_COUNT}, tag=${KSU_TAG})"
    log "Kernel KSU_VERSION: $((30000 + KSU_COUNT))"
}

install_sources() {
    local INSTALL_DIR="${SRC_DIR}-${PKGVER}"
    log "Installing kernel sources to ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"

    cp -r "${FORK_DIR}/kernel/"* "${INSTALL_DIR}/"
    cp -r "${FORK_DIR}/uapi/"* "${INSTALL_DIR}/" 2>/dev/null || true
    install -Dm644 "${SCRIPT_DIR}/Makefile" "${INSTALL_DIR}/Makefile"

    sed "s|@PKGVER@|${PKGVER}|g;
         s|@KSU_GIT_VERSION@|${KSU_COUNT}|g;
         s|@KSU_GIT_TAG@|${KSU_TAG}|g;" \
        "${SCRIPT_DIR}/dkms.conf" > "${INSTALL_DIR}/dkms.conf"
}

build_dkms() {
    log "Building DKMS module (LLVM=1)..."
    dkms remove "kernelsu-next/${PKGVER}" -k "${TARGET_KERNEL}" 2>/dev/null || true
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

usage() {
    cat <<'EOF'
KernelSU-Next UNSTABLE updater (tracks upstream dev)

WARNING: EXPERIMENTAL. Applies the Waydroid adaptation on top of the latest
UNSTABLE upstream 'dev' branch. May break; if a patch fails to apply, the
script aborts and your current module is left untouched.

Usage: sudo ./installer-update-unstable.sh [OPTIONS]

Options:
  --skip-seccomp     Do not modify Waydroid seccomp profiles
  --kernel <ver>     Target kernel version (default: uname -r)
  -h, --help         Show this help
EOF
}

main() {
    while [ $# -gt 0 ]; do
        case $1 in
            --skip-seccomp) SKIP_SECCOMP=1 ;;
            --kernel)       shift; TARGET_KERNEL="${1:-}" ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1" ;;
        esac
        shift
    done

    [ -z "${TARGET_KERNEL}" ] && TARGET_KERNEL=$(uname -r)

    need_root "$@"

    echo ""
    err "=== UNSTABLE BUILD — NOT RECOMMENDED FOR DAILY USE ==="
    echo "Tracks kernelSU-Next '${UPSTREAM_BRANCH}' (unstable). Proceed? [y/N] "
    read -r confirm
    case "$confirm" in
        y|Y|yes|YES) : ;;
        *) die "Cancelled." ;;
    esac

    check_prereqs
    clone_fork
    apply_waydroid_patches

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
    log "=== KernelSU-Next UNSTABLE installed successfully ==="
    log "Kernel version: ${TARGET_KERNEL}"
    log "KSU_VERSION:    $((30000 + KSU_COUNT))"
    log "Tag:            ${KSU_TAG}"
    log "Rebased tree:   ${FORK_DIR}"
    log ""
    log "Remember this is an UNSTABLE (dev) build. Reinstall the stable one"
    log "(sudo ./install.sh) when a proper release lands."
}

main "$@"
