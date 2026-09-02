# kernelsu-dkms

KernelSU-Next kernel module (LKM) for x86_64 Waydroid, packaged via DKMS.

Builds `kernelsu.ko` against your running kernel and auto-rebuilds on kernel updates.
Loads via `modloader` (not `modprobe`) to avoid symbol resolution issues in non-Android kernels.

## Quick install

```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Polaricito/KernelSU-Next-DKMS/master/installer.sh)"
```

This clones the repo, builds the module with DKMS, loads it, installs systemd services,
applies the Waydroid seccomp fix, and stages ksud — automatically.

Or if you already have this repo:

```sh
sudo ./install.sh
```

Both accept the same options (`--uninstall`, `--skip-seccomp`, `--kernel <ver>`).

## Uninstall

```sh
sudo ./install.sh --uninstall
```

## Manual install

For those who prefer step-by-step:

```sh
# 1. Clone the fork
git clone --depth 1 -b waydroid https://github.com/Polaricito/KernelSU-Next-Waydroid.git /tmp/kernelsu-next

# 2. Copy sources to /usr/src
sudo mkdir -p /usr/src/kernelsu-next
sudo cp -r /tmp/kernelsu-next/kernel/* /usr/src/kernelsu-next/
sudo cp -r /tmp/kernelsu-next/uapi/* /usr/src/kernelsu-next/
sudo cp Makefile /usr/src/kernelsu-next/

# 3. Generate dkms.conf (compute version from git)
cd /tmp/kernelsu-next
_count=$(git rev-list --count HEAD)
_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v$_count")
sudo sed "s|@PKGVER@|0.$_count.g$(git rev-parse --short HEAD)|g;
          s|@KSU_GIT_VERSION@|$_count|g;
          s|@KSU_GIT_TAG@|$_tag|g;" \
    /path/to/kernelsu-dkms/dkms.conf | sudo tee /usr/src/kernelsu-next/dkms.conf > /dev/null

# 4. Build + install
sudo bash -c 'LLVM=1 dkms build kernelsu-next/0.$(cd /usr/src/kernelsu-next && git rev-list --count HEAD).g$(cd /usr/src/kernelsu-next && git rev-parse --short HEAD) -k $(uname -r)'
sudo dkms install kernelsu-next/<version> -k $(uname -r)

# 5. Load
sudo /usr/bin/load-kernelsu

# 6. Install services
sudo install -m644 kernelsu-autload.service /etc/systemd/system/
sudo install -m755 kernelsu-stage.sh /usr/local/sbin/
sudo systemctl enable --now kernelsu-autload.service
sudo systemctl start kernelsu-stage.service

# 7. Fix Waydroid seccomp
sudo sed -i '/^reboot$/d' /usr/lib/waydroid/data/configs/waydroid.seccomp
sudo sed -i '/^reboot$/d' /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
sudo systemctl restart waydroid-container.service
```

## Configuration

Build options in `Makefile`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CONFIG_KSU` | `m` | Module mode (required for DKMS) |
| `CONFIG_KSU_NON_ANDROID` | `y` | Disable PID=1 checker (required for non-Android hosts) |
| `CONFIG_KSU_SELINUX` | `n` | SELinux support (disable on non-SELinux hosts) |
| `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` | `y` | x86_64 syscall patching for LKM mode |

To change options, edit the Makefile before running `install.sh`.

## Kernel version requirement

The Manager app (`com.rifsxd.ksunext`) requires kernel version >= 33188. The module calculates:
```
KSU_VERSION = 30000 + git_commit_count
```
So the fork needs >= 3188 commits. Check with `git rev-list --count HEAD`.

## Troubleshooting

### Module fails to load: "Unknown symbol change_pid"

Use `load-kernelsu` (modloader), not `modprobe`. Plain modprobe fails because KSU needs
PID namespace manipulation symbols that modprobe can't resolve in non-Android kernels.

### Manager shows "v0.0.1" or version too low

The DKMS build must receive `KSU_GIT_VERSION` and `KSU_GIT_TAG` at build time. Ensure
your `dkms.conf` MAKE line includes these variables. The `install.sh` handles this automatically.

### SIGSYS (Bad system call) on startup

Waydroid's LXC seccomp profile blacklists `reboot()`, which KSU uses to install its driver
file descriptor. Remove it from both seccomp profiles:

```sh
sudo sed -i '/^reboot$/d' /usr/lib/waydroid/data/configs/waydroid.seccomp
sudo sed -i '/^reboot$/d' /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
sudo systemctl restart waydroid-container.service
```

This is safe: the container lacks `CAP_SYS_BOOT`, so real reboots are still blocked.

### Module disappears after kernel update

DKMS auto-rebuilds on kernel updates. If it didn't trigger:

```sh
sudo dkms autoinstall -k $(uname -r)
```

### ksud not found in container

The Manager app stages ksud on first launch. If it's missing, either:
- Reinstall the Manager app, or
- Manually stage: `kernelsu-stage.sh` copies from `/usr/local/lib/kernelsu/ksud`

## Architecture

```
host Linux kernel                     Waydroid LXC container (x86_64 / Android)
┌────────────────────────────┐          ┌──────────────────────────────────────────┐
│ kernelsu.ko (DKMS, host)   │          │ com.rifsxd.ksunext (Manager app)         │
│   [ksu_driver] anon-inode  │◄──fd──── │   │ (libsu root shell)                   │
│   reboot() supercall kprobe│◄──────── │   ▼                                      │
│   sucompat / allowlist     │◄──────── │ /data/adb/ksud  (staged by autoload)     │
└────────────────────────────┘          └──────────────────────────────────────────┘
```

For detailed architecture notes, see [waydroid.md](waydroid.md).

## Links

- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — upstream
- [Waydroid port](https://github.com/Polaricito/KernelSU-Next-Waydroid) — fork with x86 patches
- [AUR package](https://aur.archlinux.org/packages/kernelsu-dkms) — original DKMS package by shadichy
