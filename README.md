# vmware-workstation-linux

Make **VMware Workstation** run on Linux when Secure Boot blocks its kernel
modules, on a single machine **or** across a lab of bare-metal desktops and
laptops via automated provisioning.

---

## Contents

- [The problem](#the-problem)
- [Why it happens](#why-it-happens)
- [Supported distributions](#supported-distributions)
- [Prerequisites](#prerequisites)
- [Part 1 — Fix one machine (interactive, step by step)](#part-1--fix-one-machine-interactive-step-by-step)
- [Part 2 — Lab automation (bare-metal fleets)](#part-2--lab-automation-bare-metal-fleets)
  - [2.1 Decide your Secure Boot strategy](#21-decide-your-secure-boot-strategy)
  - [2.2 One-time: create the organization signing key](#22-one-time-create-the-organization-signing-key)
  - [2.3 What the provisioning steps must do](#23-what-the-provisioning-steps-must-do)
  - [2.4 Ubuntu autoinstall (Subiquity)](#24-ubuntu-autoinstall-subiquity)
  - [2.5 Rocky Linux Kickstart](#25-rocky-linux-kickstart)
  - [2.6 Ansible role](#26-ansible-role)
  - [2.7 Enrolling the MOK on each machine](#27-enrolling-the-mok-on-each-machine)
  - [2.8 The persistent hook (survives kernel updates)](#28-the-persistent-hook-survives-kernel-updates)
- [Script reference](#script-reference)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [FAQ](#faq)
- [License](#license)

---

## The problem

Starting a VM fails with:

```
Could not open /dev/vmmon: No such file or directory.
Please make sure that the kernel module `vmmon' is loaded.
```

`vmware-modconfig` compiled the modules successfully, but `modprobe vmmon`
silently fails and `/dev/vmmon` is never created.

## Why it happens

VMware Workstation ships two out-of-tree kernel modules:

| Module   | Purpose                                   |
|----------|-------------------------------------------|
| `vmmon`  | the VM monitor — creates `/dev/vmmon`     |
| `vmnet`  | host networking — creates `/dev/vmnet*`   |

On a machine with **UEFI Secure Boot enabled**, the kernel refuses to load
any module that is not signed by a key it trusts (the firmware `db`, or a
**MOK** — Machine Owner Key — enrolled via `mokutil`/`shim`). VMware does
**not** sign these modules, so the kernel rejects them with
`Key was rejected by service` in `dmesg`, and Workstation reports the
`/dev/vmmon` error.

Confirm this is your situation:

```bash
mokutil --sb-state                                             # -> "SecureBoot enabled"
ls -l /lib/modules/$(uname -r)/misc/vmmon.ko*                  # module exists (built)
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep -c sig_id  # 0 = unsigned
sudo dmesg | grep -iE 'vmmon|key rejected|module verification'
```

The fix: generate a signing key, **sign** `vmmon`/`vmnet` with it, **enrol**
the key so Secure Boot trusts it, then load the modules. `fix-vmmon.sh`
automates every step and is safe to re-run after each kernel update.

---

## Supported distributions

| Distribution      | Versions                                   | Notes                                            |
|-------------------|--------------------------------------------|-------------------------------------------------|
| **Ubuntu**        | **LTS only** — 26.04, 24.04, 22.04, 20.04  | Interim releases (e.g. 25.10) are **not** supported |
| **Rocky Linux**   | 8, 9, 10                                    | RHEL/AlmaLinux are similar but untested          |

> **Only LTS versions of Ubuntu are supported.** Interim releases move to a
> new kernel series every six months, which repeatedly breaks out-of-tree
> modules; labs should standardise on an LTS. The script reads
> `/etc/os-release`, prints a warning if it finds a non-LTS Ubuntu or an
> untested distro, and then continues.

---

## Prerequisites

On the target machine you need `sudo`/root, plus these packages:

**Ubuntu (LTS)**

```bash
sudo apt-get update
sudo apt-get install -y linux-headers-$(uname -r) openssl mokutil zstd
```

**Rocky Linux**

```bash
sudo dnf install -y kernel-devel-$(uname -r) openssl mokutil
```

VMware Workstation itself must already be installed, and its modules must be
built at least once:

```bash
sudo vmware-modconfig --console --install-all
```

---

## Part 1 — Fix one machine (interactive, step by step)

Use this on your own workstation or a one-off machine.

### Step 1 — Get the script

```bash
git clone https://github.com/learnlinuxforwork/vmware-workstation-linux.git
cd vmware-workstation-linux
chmod +x fix-vmmon.sh
```

### Step 2 — Check the current state

```bash
./fix-vmmon.sh --status
```

Example output on a broken machine:

```
distro        : Ubuntu 24.04.1 LTS
kernel        : 6.8.0-45-generic
secure boot   : SecureBoot enabled
MOK key dir   : /home/you/.mok
MOK key       : absent
modules signed: no
/dev/vmmon    : MISSING
```

### Step 3 — Run the fix

```bash
./fix-vmmon.sh
```

It will, in order:

1. Detect the distribution (warns if unsupported, then continues).
2. Verify `vmmon.ko` / `vmnet.ko` exist (tells you to run
   `vmware-modconfig` if not).
3. If Secure Boot is **off**: load the modules and stop — you're done.
4. If Secure Boot is **on**:
   1. Generate an RSA signing key in `~/.mok/` (`MOK.priv` + `MOK.der`),
      reusing it if it already exists.
   2. Sign `vmmon.ko` and `vmnet.ko` with the running kernel's `sign-file`
      (decompressing/recompressing `.ko.zst` / `.ko.xz` if your distro uses
      compressed modules).
   3. If the key is **already enrolled**: load the modules — done.
   4. Otherwise run `mokutil --import ~/.mok/MOK.der`. **You will be asked to
      set a one-time password.** Choose something simple you can retype at
      the console; it is used only once.

### Step 4 — Reboot and enrol the key

```bash
sudo reboot
```

During boot, **shim** shows a blue **MOK Manager** screen (a 10-second
countdown — press a key to enter it):

1. Choose **Enroll MOK**
2. **Continue**
3. **Yes** to confirm
4. Enter the **one-time password** from Step 3
5. **Reboot**

> If you miss the countdown the machine boots normally and the key is *not*
> enrolled — just run `./fix-vmmon.sh` again and reboot.

### Step 5 — Load the modules and verify

After the machine is back up:

```bash
./fix-vmmon.sh --load
./fix-vmmon.sh --status
```

You want:

```
secure boot   : SecureBoot enabled
MOK key       : enrolled
modules signed: yes
/dev/vmmon    : present
```

Start VMware Workstation — the error is gone.

### Step 6 — Make it survive kernel updates

Every kernel update rebuilds `vmmon`/`vmnet` **unsigned** again. Either
re-run `./fix-vmmon.sh` after each update, or install the persistent hook
once:

```bash
sudo ./fix-vmmon.sh --install-hook
```

This copies the script to `/usr/local/sbin/fix-vmmon.sh`, installs a
`fix-vmmon.service` systemd unit that signs + loads the modules on every
boot, and (on Ubuntu) a `/etc/kernel/postinst.d/` hook that re-signs them as
soon as a new kernel is installed. The enrolled MOK keeps working across
kernel updates, so **no further reboots into MOK Manager are needed**.

---

## Part 2 — Lab automation (bare-metal fleets)

Goal: every Ubuntu LTS / Rocky desktop and laptop you image comes up with
VMware Workstation working, with no per-machine manual steps beyond (at
most) a single console confirmation the first time.

### 2.1 Decide your Secure Boot strategy

MOK enrolment **cannot be fully automated** — `shim` deliberately requires a
physical person at the console to approve a new key once per machine. Pick
one approach for the whole lab:

| Strategy | How | Trade-off |
|---|---|---|
| **A. Shared organization MOK** *(recommended)* | Generate **one** key pair (§2.2). Deliver it to every machine during imaging. A technician approves it **once** in MOK Manager during first boot (§2.7). All future kernel updates are re-signed automatically with no reboot. | One console touch per machine at imaging time (you're already there). |
| **B. Disable Secure Boot** | Turn Secure Boot off in the BIOS/UEFI baseline (or via vendor tooling: Dell `cctk`, HP BCU, Lenovo). No signing needed at all. | Weaker boot integrity; some orgs disallow it. |
| **C. Pre-enroll at image-build time** | Build your golden image in a VM/'`mokutil --import`' + scripted MOK Manager, or inject the cert into the firmware `db` with vendor tooling. | Most complex; firmware-dependent. |

The script supports A and B directly. B is simply: Secure Boot off →
`fix-vmmon.sh` (or the systemd unit) loads the modules with no key.

### 2.2 One-time: create the organization signing key

Do this **once**, on a secure admin host. Keep `MOK.priv` secret (treat it
like an SSH CA key); `MOK.der` is the public cert and can be distributed
freely.

```bash
umask 077
mkdir -p ~/vmware-lab-mok && cd ~/vmware-lab-mok
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout MOK.priv -outform DER -out MOK.der \
  -subj "/CN=ACME Lab VMware Module Signing/"
```

Store `MOK.priv` + `MOK.der` where your provisioning system can fetch them
securely (Ansible Vault, an internal artifact repo, a kickstart HTTPS
server, an MDM payload, …). On each machine they must land in a directory
referenced by `MOK_DIR` (default for root runs: `/var/lib/fix-vmmon`).

### 2.3 What the provisioning steps must do

On every target, in this order:

1. Install prerequisites (headers, `openssl`, `mokutil`, `zstd`).
2. Install VMware Workstation and run `vmware-modconfig --console --install-all`.
3. Create `/var/lib/fix-vmmon/` and drop in `MOK.priv` (mode 600) and
   `MOK.der` (mode 644) from §2.2.
4. Install the script + hook: `fix-vmmon.sh --install-hook`.
5. Queue MOK enrolment non-interactively:
   `MOK_PASSWORD=<lab-secret> fix-vmmon.sh --enroll`.
6. On first boot, a technician approves the key in MOK Manager (§2.7).
   From then on `fix-vmmon.service` signs + loads on every boot and after
   every kernel update — hands-off.

If you chose **Strategy B (Secure Boot off)**, skip steps 3, 5 and 6 — the
hook alone is enough.

### 2.4 Ubuntu autoinstall (Subiquity)

`user-data` — the `late-commands` run in the installer against the target
root at `/target`:

```yaml
#cloud-config
autoinstall:
  version: 1
  packages:
    - openssl
    - mokutil
    - zstd
    # linux-headers-generic pulls headers matching the installed kernel
    - linux-headers-generic
  late-commands:
    # 1. Organization MOK, fetched over HTTPS from your provisioning server
    - curl -fsSL https://provision.acme.internal/vmware/MOK.der -o /target/var/lib/fix-vmmon/MOK.der --create-dirs
    - curl -fsSL https://provision.acme.internal/vmware/MOK.priv -o /target/var/lib/fix-vmmon/MOK.priv
    - chmod 600 /target/var/lib/fix-vmmon/MOK.priv
    - chmod 644 /target/var/lib/fix-vmmon/MOK.der
    # 2. The fix script
    - curl -fsSL https://provision.acme.internal/vmware/fix-vmmon.sh -o /target/usr/local/sbin/fix-vmmon.sh
    - chmod 755 /target/usr/local/sbin/fix-vmmon.sh
    # 3. VMware Workstation install (your bundle/URL) + module build, in the target
    - curtin in-target --target=/target -- bash -c '/opt/pkg/VMware-Workstation.bundle --console --required --eulas-agreed && vmware-modconfig --console --install-all'
    # 4. Install the boot/kernel hook, then queue MOK enrolment
    - curtin in-target --target=/target -- /usr/local/sbin/fix-vmmon.sh --install-hook
    - curtin in-target --target=/target -- env MOK_PASSWORD=ChangeMe123 NONINTERACTIVE=1 /usr/local/sbin/fix-vmmon.sh --enroll
```

> Replace `ChangeMe123` with a value pulled from your secret store, and the
> URLs/bundle path with your own. On first boot the technician enrols the
> MOK (§2.7); `fix-vmmon.service` handles everything afterward.

### 2.5 Rocky Linux Kickstart

```kickstart
# ... your usual partitioning / packages ...

%packages
openssl
mokutil
%end

%post --log=/root/ks-post-vmmon.log
set -euxo pipefail

# Kernel headers matching the installed kernel
dnf install -y "kernel-devel-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | tail -1)"

# 1. Organization MOK
mkdir -p /var/lib/fix-vmmon
curl -fsSL https://provision.acme.internal/vmware/MOK.der  -o /var/lib/fix-vmmon/MOK.der
curl -fsSL https://provision.acme.internal/vmware/MOK.priv -o /var/lib/fix-vmmon/MOK.priv
chmod 600 /var/lib/fix-vmmon/MOK.priv
chmod 644 /var/lib/fix-vmmon/MOK.der

# 2. VMware Workstation + module build (your bundle)
/opt/pkg/VMware-Workstation.bundle --console --required --eulas-agreed
vmware-modconfig --console --install-all

# 3. Fix script + persistent hook
curl -fsSL https://provision.acme.internal/vmware/fix-vmmon.sh -o /usr/local/sbin/fix-vmmon.sh
chmod 755 /usr/local/sbin/fix-vmmon.sh
/usr/local/sbin/fix-vmmon.sh --install-hook

# 4. Queue MOK enrolment (Rocky re-signs on next boot via fix-vmmon.service)
MOK_PASSWORD="ChangeMe123" NONINTERACTIVE=1 /usr/local/sbin/fix-vmmon.sh --enroll
%end
```

### 2.6 Ansible role

For fleets already under configuration management. Idempotent — safe to run
on every check-in.

```yaml
# roles/vmware_vmmon/defaults/main.yml
vmware_mok_password: "{{ vault_vmware_mok_password }}"   # from Ansible Vault

# roles/vmware_vmmon/tasks/main.yml
- name: Install prerequisites (Ubuntu)
  ansible.builtin.apt:
    name: [openssl, mokutil, zstd, "linux-headers-{{ ansible_kernel }}"]
    state: present
    update_cache: true
  when: ansible_distribution == "Ubuntu"

- name: Install prerequisites (Rocky)
  ansible.builtin.dnf:
    name: [openssl, mokutil, "kernel-devel-{{ ansible_kernel }}"]
    state: present
  when: ansible_distribution == "Rocky"

- name: Deliver organization MOK
  ansible.builtin.copy:
    src: "{{ item.src }}"
    dest: "/var/lib/fix-vmmon/{{ item.dest }}"
    mode: "{{ item.mode }}"
  loop:
    - { src: MOK.priv, dest: MOK.priv, mode: "0600" }
    - { src: MOK.der,  dest: MOK.der,  mode: "0644" }

- name: Install fix-vmmon.sh
  ansible.builtin.copy:
    src: fix-vmmon.sh
    dest: /usr/local/sbin/fix-vmmon.sh
    mode: "0755"

- name: Build VMware modules if missing
  ansible.builtin.command: vmware-modconfig --console --install-all
  args:
    creates: "/lib/modules/{{ ansible_kernel }}/misc/vmmon.ko"

- name: Install persistent hook (systemd unit + Ubuntu kernel hook)
  ansible.builtin.command: /usr/local/sbin/fix-vmmon.sh --install-hook
  args:
    creates: /etc/systemd/system/fix-vmmon.service

- name: Queue MOK enrolment (no-op if already enrolled)
  ansible.builtin.command: /usr/local/sbin/fix-vmmon.sh --enroll
  environment:
    MOK_PASSWORD: "{{ vmware_mok_password }}"
    NONINTERACTIVE: "1"
  register: enroll
  changed_when: "'already enrolled' not in enroll.stdout"

- name: Report state
  ansible.builtin.command: /usr/local/sbin/fix-vmmon.sh --status
  changed_when: false
  register: vmmon_status
- ansible.builtin.debug:
    var: vmmon_status.stdout_lines
```

### 2.7 Enrolling the MOK on each machine

After `--enroll` has queued the key (kickstart/autoinstall/Ansible above),
the machine must reboot **once** with a person present:

1. Reboot the machine.
2. At the blue **MOK Manager** screen: **Enroll MOK → View key** (optional,
   to confirm the CN) **→ Continue → Yes →** enter the **`MOK_PASSWORD`** you
   set → **Reboot**.
3. Done. `fix-vmmon.service` signs and loads the modules on this and every
   subsequent boot.

Check pending requests any time with `mokutil --list-new`; check what's
enrolled with `mokutil --list-enrolled | grep -i acme`.

> **Tip for imaging lines:** do this at the bench right after imaging, while
> the technician still has the machine. It's ~15 seconds per unit. With
> Strategy B (Secure Boot off) it isn't needed at all.

### 2.8 The persistent hook (survives kernel updates)

`fix-vmmon.sh --install-hook` sets up:

| File | Role |
|---|---|
| `/usr/local/sbin/fix-vmmon.sh` | canonical copy of the script |
| `/etc/systemd/system/fix-vmmon.service` | oneshot unit, `--sign-and-load` on every boot (both distros) |
| `/etc/kernel/postinst.d/zz-fix-vmmon` | **Ubuntu only** — re-sign `vmmon`/`vmnet` the moment a new kernel is installed, before reboot |

On **Rocky**, there is no `postinst.d`; the new kernel's modules are signed
by `fix-vmmon.service` on the first boot into that kernel, which runs before
`vmware` starts a VM.

Optional `/etc/fix-vmmon.conf` (sourced by the script) to override defaults
fleet-wide:

```bash
# /etc/fix-vmmon.conf
MOK_DIR=/var/lib/fix-vmmon
MOK_CN="ACME Lab VMware Module Signing"
```

---

## Script reference

```
fix-vmmon.sh [MODE]

(no mode)          Interactive fix: detect → sign → enrol key → print reboot steps.
--load            depmod + modprobe vmmon vmnet, then verify /dev/vmmon.
--sign-only       Sign the modules with the existing key. No enrol, no load, no prompts.
                  Used by the Ubuntu kernel post-install hook.
--sign-and-load   Sign (if Secure Boot on and a key is present) then load.
                  Used by fix-vmmon.service at boot.
--enroll          Queue the key with mokutil. Non-interactive when MOK_PASSWORD is set
                  or stdin is not a TTY. Still requires one console approval + reboot.
--install-hook    Install /usr/local/sbin copy, systemd unit, and (Ubuntu) kernel hook.
--uninstall-hook  Remove the above. Leaves the MOK key and firmware enrolment intact.
--status          Print distro / kernel / Secure Boot / key / signed / device state.
--help            This text.

Environment / /etc/fix-vmmon.conf:
  MOK_DIR         Key directory. Default: /var/lib/fix-vmmon (root) or ~/.mok (user).
  MOK_CN          CN for a newly generated cert.
  MOK_PASSWORD    One-time enrolment password for non-interactive --enroll.
  KVER            Target kernel version. Default: uname -r.
  NONINTERACTIVE  1 to never prompt (auto-set when stdin is not a TTY).
```

Exit code is non-zero on any hard failure (modules not built, no key when
one is required, `sign-file` missing, `/dev/vmmon` still absent after load).

---

## Verification

```bash
# Secure Boot state
mokutil --sb-state

# Is our key enrolled?
sudo mokutil --test-key /var/lib/fix-vmmon/MOK.der    # -> "is already enrolled"

# Are the modules signed, and by whom?
modinfo vmmon | grep -E 'sig_id|signer'
modinfo vmnet | grep -E 'sig_id|signer'

# Are they loaded and is the device present?
lsmod | grep -E 'vmmon|vmnet'
ls -l /dev/vmmon /dev/vmnet*

# One-shot summary
sudo /usr/local/sbin/fix-vmmon.sh --status
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `modprobe: ERROR: could not insert 'vmmon': Key was rejected by service` | Key not enrolled yet, or modules signed with a different key. Reboot into MOK Manager and enrol; or re-run `fix-vmmon.sh --sign-only`. |
| MOK Manager never appears at boot | Enrolment wasn't queued. Run `mokutil --list-new` — if empty, run `fix-vmmon.sh --enroll` again. |
| `sign-file not found` | Kernel headers/devel package missing or mismatched. `apt install linux-headers-$(uname -r)` / `dnf install kernel-devel-$(uname -r)`. |
| `vmmon/vmnet not found under /lib/modules/.../misc` | Modules never built. `sudo vmware-modconfig --console --install-all`. |
| Works now, breaks after a kernel update | Install the persistent hook: `sudo fix-vmmon.sh --install-hook`. |
| `modinfo vmmon` shows no `sig_id` after signing | Distro ships compressed modules and the recompress step was skipped — install `zstd`, then re-run `fix-vmmon.sh --sign-only`. |
| Non-interactive `--enroll` exits `Non-interactive enrol needs MOK_PASSWORD set` | Export `MOK_PASSWORD` (from your secret store) in that step's environment. |
| Rocky: new kernel VM fails on first boot before the unit runs | `systemctl start fix-vmmon.service` then start the VM; the ordering is fixed from the next boot. |
| Secure Boot is already **disabled** | You don't need a key at all — `fix-vmmon.sh --load` (or the systemd unit) is enough. |

Collect diagnostics for a bug report:

```bash
sudo /usr/local/sbin/fix-vmmon.sh --status
sudo dmesg | grep -iE 'vmmon|vmnet|mok|secure ?boot|key rejected'
journalctl -u fix-vmmon.service --no-pager
```

---

## Uninstall

```bash
# Remove the hook, unit, and installed script copy
sudo /usr/local/sbin/fix-vmmon.sh --uninstall-hook

# (optional) forget the signing key on this machine
sudo rm -rf /var/lib/fix-vmmon

# (optional) remove the key from firmware — prompts for a password, then reboot
sudo mokutil --delete /var/lib/fix-vmmon/MOK.der
```

---

## FAQ

**Does this modify Secure Boot or disable any security?**
No. It adds *your own* key to the machine's trust store (the same mechanism
NVIDIA/VirtualBox DKMS use) and signs only `vmmon`/`vmnet` with it. Secure
Boot stays on and keeps verifying everything else.

**Is the RSA-2048 / SHA-256 key OK?**
Yes — that's what the kernel's own module-signing facility expects. The
per-machine key in Part 1 is set to a long validity so you never think about
it again; the org key in Part 2 uses a 10-year validity you can rotate.

**Can I use one key for the whole lab?**
Yes — that's Strategy A. One `MOK.priv`/`MOK.der`, delivered to every
machine, enrolled once per machine.

**What about `evdi`, `nvidia`, VirtualBox, other out-of-tree modules?**
Same problem, same fix. You can reuse the org key and add their `.ko` paths;
this script only manages `vmmon`/`vmnet`.

**Ubuntu non-LTS?**
Not supported. Standardise the lab on an LTS release.

---

## License

GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`) — see
[LICENSE](LICENSE). If you run a modified version of this script as part of a
network service, the AGPL requires you to offer that service's users the
corresponding modified source.

Copyright (C) 2026 sheastech and contributors — see [AUTHORS](AUTHORS).
