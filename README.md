# vmware-workstation-linux

Fixes for running **VMware Workstation** on Linux.

## Supported distributions

| Distribution | Versions |
|---|---|
| **Ubuntu** | **LTS releases only** — 26.04, 24.04, 22.04, 20.04 |
| **Rocky Linux** | 8, 9, 10 |

> **Note:** Only **LTS** versions of Ubuntu are supported. Interim releases
> (e.g. 25.10) ship newer kernels on a faster cadence and are not tracked
> here. Other distributions may work — the script detects the OS, warns if
> it is unsupported, and continues — but they are untested.

## `Could not open /dev/vmmon: No such file or directory`

```
Could not open /dev/vmmon: No such file or directory.
Please make sure that the kernel module `vmmon' is loaded.
```

### Cause

On a machine with **Secure Boot enabled**, the kernel only loads modules
signed by a key it trusts. VMware's `vmmon` and `vmnet` modules compile
fine (via `vmware-modconfig`) but are **unsigned**, so `modprobe vmmon`
is rejected and `/dev/vmmon` is never created.

Confirm this is your case:

```bash
mokutil --sb-state                                            # -> SecureBoot enabled
ls /lib/modules/$(uname -r)/misc/vmmon.ko                     # module exists (built)
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep sig_id  # no output = unsigned
```

### Fix

Sign the modules with a Machine Owner Key (MOK) and enrol that key so
Secure Boot trusts them.

```bash
./fix-vmmon.sh
```

The script:

1. Detects the distribution and warns if it is not a supported
   Ubuntu LTS or Rocky Linux release.
2. Verifies `vmmon.ko` / `vmnet.ko` exist (points you at
   `sudo vmware-modconfig --console --install-all` if not).
3. If Secure Boot is off, just loads the modules and exits.
4. Generates a MOK key pair in `~/.mok/` (reused on later runs).
5. Signs `vmmon.ko` and `vmnet.ko` with the running kernel's `sign-file`,
   handling `.ko.zst` / `.ko.xz` compressed modules if the distro uses them.
6. If the key is already enrolled, loads the modules — done.
7. Otherwise runs `mokutil --import` (asks you to set a one-time
   password) and prints the reboot steps.

Then reboot. On the blue **MOK Manager** screen:

> Enroll MOK → Continue → Yes → *enter the password you set*

After it boots:

```bash
./fix-vmmon.sh --load
```

### After a kernel update

VMware rebuilds the modules unsigned again. Just re-run `./fix-vmmon.sh` —
it sees the key is already enrolled, re-signs, and loads the modules with
no second reboot.

### Alternative: disable Secure Boot

If you don't want to manage a signing key, disable Secure Boot in your
UEFI firmware settings, then:

```bash
sudo modprobe vmmon vmnet
```

## Requirements

`sudo` access, plus `openssl`, `mokutil`, and the kernel headers/devel
package for the running kernel:

**Ubuntu (LTS)**

```bash
sudo apt install linux-headers-$(uname -r) openssl mokutil
```

**Rocky Linux**

```bash
sudo dnf install kernel-devel-$(uname -r) openssl mokutil
```

## License

MIT — see [LICENSE](LICENSE).
