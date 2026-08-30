# vmware-workstation-linux

Fixes for running **VMware Workstation** on Linux.

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
mokutil --sb-state                                   # -> SecureBoot enabled
ls /lib/modules/$(uname -r)/misc/vmmon.ko            # module exists (built)
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep sig_id   # no output = unsigned
```

### Fix

Sign the modules with a Machine Owner Key (MOK) and enrol that key so
Secure Boot trusts them.

```bash
./fix-vmmon.sh
```

The script:

1. Verifies `vmmon.ko` / `vmnet.ko` exist (points you at
   `sudo vmware-modconfig --console --install-all` if not).
2. If Secure Boot is off, just loads the modules and exits.
3. Generates a MOK key pair in `~/.mok/` (reused on later runs).
4. Signs `vmmon.ko` and `vmnet.ko` with the running kernel's `sign-file`.
5. If the key is already enrolled, loads the modules — done.
6. Otherwise runs `mokutil --import` (asks you to set a one-time
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

- `openssl`, `mokutil`, and kernel headers for the running kernel
  (`linux-headers-$(uname -r)`).
- `sudo` access.

## License

MIT — see [LICENSE](LICENSE).
