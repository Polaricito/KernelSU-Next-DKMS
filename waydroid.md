# KernelSU-Next in Waydroid (KernelSU-Next-Waydroid port)

Deployment notes for running the `waydroid` branch port of KernelSU-Next inside a
hosted Waydroid container on Arch/CachyOS.

## Architecture

```
host Linux kernel                     Waydroid LXC container (x86_64 / Android 13)
┌──────────────────────────┐          ┌──────────────────────────────────────────┐
│ kernelsu.ko (DKMS, host) │          │ com.rifsxd.ksunext (Manager app)         │
│   [ksu_driver] anon-inode│ ◄──fd─── │   │ (libsu root shell)                   │
│   reboot() supercall kprobe ◄─────  │   ▼                                     │
│   sucompat / allowlist  ◄────────── │ /data/adb/ksud  (staged by autoload)    │
└──────────────────────────┘          └──────────────────────────────────────────┘
```

- The module runs on the **host** kernel; the container shares it (LXC).
- ksud is staged into the container's `/data/adb` via the host bind
  (`/home/meowl/.local/share/waydroid/data`).
- The Manager talks to ksud per-command over a libsu root shell; the kernel grants
  root via `[ksu_driver]` ioctls and the allowlist.

## The critical fix: LXC seccomp blocks the `reboot()` supercall

ksud installs its `[ksu_driver]` fd by calling the kernel's `reboot()` syscall with
KSU's magic values (`KSU_INSTALL_MAGIC1/MAGIC2`, see `uapi/supercall.h`). Waydroid's
LXC seccomp profile **blacklists `reboot`**, so every supercall died with
`Bad system call (SIGSYS)` before reaching the kernel kprobe.

Fix: remove `reboot` from the seccomp blacklist, in BOTH:
- the live profile `/var/lib/waydroid/lxc/waydroid/waydroid.seccomp`, and
- the package template `/usr/lib/waydroid/data/configs/waydroid.seccomp`
  (re-copied to the live path on every container config generation).

This is safe: the container lacks `CAP_SYS_BOOT`, so a genuine `reboot()` is still
denied by the capability check; only KSU's fd-install magic (cmd 0) passes through.

```sh
sudo sed -i '/^reboot$/d' /usr/lib/waydroid/data/configs/waydroid.seccomp
sudo sed -i '/^reboot$/d' /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
sudo systemctl restart waydroid-container.service
```

> Note: package updates to `waydroid` will restore the stock seccomp template.
> Re-apply the sed if root stops working after an upgrade.

## Automatic start (systemd)

- `kernelsu-autload.service` — loads the host module at boot via
  `load-kernelsu` (modloader), before `waydroid-container.service`.
- `kernelsu-stage.service` — idempotently stages `/data/adb/ksud` +
  `/data/adb/ksu/bin/{ksud,resetprop,busybox}` into the container `/data` bind;
  mirrors `ksud install` (assets.rs / defs.rs symlink semantics).

Install:

```sh
sudo install -m644 kernelsu-autload.service /etc/systemd/system/
sudo install -m755 kernelsu-stage.sh /usr/local/sbin/
sudo systemctl enable --now kernelsu-autload.service
sudo systemctl start kernelsu-stage.service
```

`kernelsu-stage.sh` copies `ksud` from `/usr/local/lib/kernelsu/ksud`
(`KERNELSU_KSU_BIN` overrides) and the checked-in busybox next to it.

## Session note

`waydroid-container.service` holds the container service but does not spawn
`lxc-start`; the LXC container is launched by the graphical session:

```sh
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" XDG_RUNTIME_DIR=/run/user/1000
setsid waydroid session start
```

## Verification

Once the container is up (root shell as the host user):

```sh
sudo waydroid shell
uname -r                    # == host kernel; kernelsu visible in /proc/modules
/data/adb/ksud feature get su_compat   # Value: 1 (proves driver fd works)
dmesg | grep "allow root for: 10149"   # Manager app being granted root
```

The Manager (`com.rifsxd.ksunext`) connects via its bundled `libksud.so` root
shell; `allow root for: <appuid>` lines in `dmesg` confirm grants.