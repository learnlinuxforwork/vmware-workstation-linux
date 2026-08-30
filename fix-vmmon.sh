#!/usr/bin/env bash
#
# fix-vmmon.sh — Make VMware Workstation's vmmon/vmnet kernel modules load
# on a Secure Boot system by signing them with a Machine Owner Key (MOK).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 sheastech
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version. It is distributed WITHOUT ANY WARRANTY. See the
# GNU AGPL <https://www.gnu.org/licenses/> for details.
#
# Supported distributions:
#   * Ubuntu — LTS releases only (26.04, 24.04, 22.04, 20.04)
#   * Rocky Linux 8 / 9 / 10
# Other distros may work but are untested; the script warns and continues.
#
# Interactive use (single machine):
#   ./fix-vmmon.sh                 detect, sign, enrol key, print reboot steps
#   ./fix-vmmon.sh --load          just (re)load the modules
#
# Automation use (lab provisioning, run as root):
#   ./fix-vmmon.sh --enroll        import a pre-generated key non-interactively
#                                  (needs MOK_PASSWORD; still needs one reboot)
#   ./fix-vmmon.sh --sign-only     sign modules with the existing key, nothing else
#   ./fix-vmmon.sh --sign-and-load sign (if needed) then load — used by the boot unit
#   ./fix-vmmon.sh --install-hook  install /usr/local/sbin copy + systemd unit
#                                  (+ kernel postinst hook on Ubuntu)
#   ./fix-vmmon.sh --uninstall-hook
#   ./fix-vmmon.sh --status        print Secure Boot / key / module / device state
#
# Configuration (environment or /etc/fix-vmmon.conf, which is sourced if present):
#   MOK_DIR        directory holding MOK.priv / MOK.der
#                  default: /var/lib/fix-vmmon when root, else ~/.mok
#   MOK_CN         certificate common name for a freshly generated key
#   MOK_PASSWORD   one-time enrolment password for --enroll (non-interactive)
#   KVER           target kernel version (default: uname -r)
#   NONINTERACTIVE 1 to never prompt (auto-set when stdin is not a TTY)
#
set -euo pipefail

# --- configuration ----------------------------------------------------------

[[ -r /etc/fix-vmmon.conf ]] && . /etc/fix-vmmon.conf

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

KVER="${KVER:-$(uname -r)}"
if [[ $EUID -eq 0 ]]; then
  MOK_DIR="${MOK_DIR:-/var/lib/fix-vmmon}"
else
  MOK_DIR="${MOK_DIR:-${HOME}/.mok}"
fi
MOK_PRIV="${MOK_DIR}/MOK.priv"
MOK_DER="${MOK_DIR}/MOK.der"
MOK_CN="${MOK_CN:-VMware Module Signing ($(hostname -s 2>/dev/null || echo lab))}"
MOK_PASSWORD="${MOK_PASSWORD:-}"

MOD_DIR="/lib/modules/${KVER}/misc"
MODULES=(vmmon vmnet)

INSTALL_PATH="/usr/local/sbin/fix-vmmon.sh"
UNIT_PATH="/etc/systemd/system/fix-vmmon.service"
UBUNTU_HOOK="/etc/kernel/postinst.d/zz-fix-vmmon"

[[ -t 0 ]] || NONINTERACTIVE="${NONINTERACTIVE:-1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

DISTRO_ID="" DISTRO_VERSION="" DISTRO_PRETTY=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n'  "$*" >&2; exit 1; }

# --- distro handling ------------------------------------------------------

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION}"
  fi

  case "$DISTRO_ID" in
    ubuntu)
      local major="${DISTRO_VERSION%%.*}" minor="${DISTRO_VERSION#*.}"
      if [[ -n "$major" && -n "$minor" && $((major % 2)) -eq 0 && "$minor" == "04" ]]; then
        log "Detected ${DISTRO_PRETTY} (LTS) — supported."
      else
        warn "Detected ${DISTRO_PRETTY}."
        warn "Only Ubuntu LTS releases (XX.04, even year) are supported. Continuing anyway."
      fi
      ;;
    rocky)
      local major="${DISTRO_VERSION%%.*}"
      if [[ -n "$major" && "$major" -ge 8 ]]; then
        log "Detected ${DISTRO_PRETTY} — supported."
      else
        warn "Detected ${DISTRO_PRETTY}. Rocky Linux 8/9/10 are supported. Continuing anyway."
      fi
      ;;
    "") warn "Could not read /etc/os-release — distribution unknown. Continuing anyway." ;;
    *)  warn "Detected ${DISTRO_PRETTY}. Supported: Ubuntu LTS and Rocky Linux 8/9/10."
        warn "This distro is untested; continuing anyway." ;;
  esac
}

headers_hint() {
  case "$DISTRO_ID" in
    ubuntu) echo "$SUDO apt-get install -y linux-headers-${KVER} openssl mokutil zstd" ;;
    rocky)  echo "$SUDO dnf install -y kernel-devel-${KVER} openssl mokutil" ;;
    *)      echo "install the kernel headers/devel package for ${KVER}, plus openssl and mokutil" ;;
  esac
}

# --- helpers ------------------------------------------------------------

find_sign_file() {
  for p in \
    "/lib/modules/${KVER}/build/scripts/sign-file" \
    "/usr/src/linux-headers-${KVER}/scripts/sign-file" \
    "/usr/src/kernels/${KVER}/scripts/sign-file"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

secure_boot_on() {
  command -v mokutil >/dev/null 2>&1 || return 1
  mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

key_enrolled() {
  [[ -f "$MOK_DER" ]] || return 1
  $SUDO mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi 'already enrolled'
}

module_path() {
  for f in "${MOD_DIR}/$1.ko" "${MOD_DIR}/$1.ko.zst" "${MOD_DIR}/$1.ko.xz"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

module_is_signed() { modinfo "$1" 2>/dev/null | grep -q '^sig_id:'; }

modules_present() {
  local m
  for m in "${MODULES[@]}"; do module_path "$m" >/dev/null || return 1; done
}

require_modules() {
  modules_present || die "vmmon/vmnet not found under ${MOD_DIR}. Build them first:
  $SUDO vmware-modconfig --console --install-all"
}

ensure_key() {
  if [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]]; then
    log "Using MOK key in ${MOK_DIR}"
    return
  fi
  [[ "$NONINTERACTIVE" == 1 ]] && \
    warn "No key in ${MOK_DIR}; generating one. For a lab, deliver a shared key here instead."
  log "Generating MOK key in ${MOK_DIR}"
  $SUDO mkdir -p "$MOK_DIR"; $SUDO chmod 700 "$MOK_DIR"
  $SUDO openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout "$MOK_PRIV" -outform DER -out "$MOK_DER" -subj "/CN=${MOK_CN}/"
  $SUDO chmod 600 "$MOK_PRIV"
}

sign_one() {
  local ko; ko="$(module_path "$1")" || die "$1 module missing under ${MOD_DIR}"

  case "$ko" in
    *.zst) log "Decompressing $(basename "$ko")"; $SUDO unzstd -qf "$ko"; ko="${ko%.zst}" ;;
    *.xz)  log "Decompressing $(basename "$ko")"; $SUDO xz -dqf "$ko";     ko="${ko%.xz}"  ;;
  esac

  if module_is_signed "$ko"; then
    log "$(basename "$ko") already signed"
  else
    log "Signing $(basename "$ko")"
    $SUDO "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$ko"
    module_is_signed "$ko" || warn "  signature not detected on $(basename "$ko")"
  fi

  if compgen -G "${MOD_DIR}/*.ko.zst" >/dev/null 2>&1 && [[ "$ko" != *.zst ]]; then
    log "Recompressing $(basename "$ko").zst"; $SUDO zstd -qf --rm "$ko"
  elif compgen -G "${MOD_DIR}/*.ko.xz" >/dev/null 2>&1 && [[ "$ko" != *.xz ]]; then
    log "Recompressing $(basename "$ko").xz";  $SUDO xz -qf "$ko"
  fi
}

sign_modules() {
  require_modules
  SIGN_FILE="$(find_sign_file)" || die "sign-file not found. Install kernel headers:
  $(headers_hint)"
  log "Using sign-file: ${SIGN_FILE}"
  [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]] || die "No signing key at ${MOK_DIR}. Generate/deliver one first."
  local m; for m in "${MODULES[@]}"; do sign_one "$m"; done
}

load_modules() {
  require_modules
  log "depmod + modprobe ${MODULES[*]}"
  $SUDO depmod -a "$KVER"
  $SUDO modprobe "${MODULES[@]}"
  if [[ -e /dev/vmmon ]]; then
    log "Success — /dev/vmmon present:"
    ls -l /dev/vmmon /dev/vmnet* 2>/dev/null || true
    return 0
  fi
  die "modprobe returned but /dev/vmmon still missing — check: $SUDO dmesg | tail"
}

enroll_key() {
  [[ -f "$MOK_DER" ]] || die "No key at ${MOK_DER} to enrol."
  if key_enrolled; then log "Key already enrolled in firmware."; return 0; fi

  if [[ "$NONINTERACTIVE" == 1 || -n "$MOK_PASSWORD" ]]; then
    [[ -n "$MOK_PASSWORD" ]] || die "Non-interactive enrol needs MOK_PASSWORD set."
    log "Queuing key for enrolment (non-interactive)"
    printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | $SUDO mokutil --import "$MOK_DER"
  else
    log "Queuing key for enrolment. Set a one-time password when prompted."
    warn "You must retype it in the blue 'MOK Manager' screen after reboot."
    $SUDO mokutil --import "$MOK_DER"
  fi

  cat <<EOF

------------------------------------------------------------------------
Reboot to finish enrolment. On the blue MOK Manager screen:
    Enroll MOK  ->  Continue  ->  Yes  ->  (enter the enrolment password)
Then:  ${INSTALL_PATH:-$0} --load
------------------------------------------------------------------------
EOF
}

install_hook() {
  [[ $EUID -eq 0 ]] || die "--install-hook must run as root."
  detect_distro

  log "Installing script to ${INSTALL_PATH}"
  install -m 0755 "$0" "$INSTALL_PATH"

  log "Writing ${UNIT_PATH}"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Sign and load VMware vmmon/vmnet kernel modules
After=vmware.service
ConditionPathExistsGlob=/lib/modules/*/misc/vmmon.ko*

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=NONINTERACTIVE=1
ExecStart=${INSTALL_PATH} --sign-and-load

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable fix-vmmon.service

  if [[ "$DISTRO_ID" == "ubuntu" ]]; then
    log "Writing Ubuntu kernel post-install hook ${UBUNTU_HOOK}"
    mkdir -p "$(dirname "$UBUNTU_HOOK")"
    cat > "$UBUNTU_HOOK" <<EOF
#!/bin/sh
# Re-sign vmmon/vmnet for a newly installed kernel. \$1 = kernel version.
set -e
[ -n "\$1" ] || exit 0
NONINTERACTIVE=1 KVER="\$1" ${INSTALL_PATH} --sign-only || true
EOF
    chmod 0755 "$UBUNTU_HOOK"
  else
    log "Rocky/other: kernel updates are re-signed by fix-vmmon.service on next boot."
  fi

  log "Hook installed. It runs at every boot and after Ubuntu kernel updates."
}

uninstall_hook() {
  [[ $EUID -eq 0 ]] || die "--uninstall-hook must run as root."
  systemctl disable --now fix-vmmon.service 2>/dev/null || true
  rm -f "$UNIT_PATH" "$UBUNTU_HOOK" "$INSTALL_PATH"
  systemctl daemon-reload || true
  log "Hook removed. The MOK key in ${MOK_DIR} and firmware enrolment are left intact."
}

status() {
  detect_distro
  local sb key sig dev
  sb=$(mokutil --sb-state 2>/dev/null | head -1 || echo "unknown")
  if key_enrolled; then key="enrolled"; elif [[ -f "$MOK_DER" ]]; then key="present, NOT enrolled"; else key="absent"; fi
  if modules_present; then
    sig="yes"; local m
    for m in "${MODULES[@]}"; do module_is_signed "$(module_path "$m")" || sig="no"; done
  else sig="modules not built"; fi
  dev=$([[ -e /dev/vmmon ]] && echo present || echo MISSING)

  cat <<EOF
distro        : ${DISTRO_PRETTY:-unknown}
kernel        : ${KVER}
secure boot   : ${sb}
MOK key dir   : ${MOK_DIR}
MOK key       : ${key}
modules signed: ${sig}
/dev/vmmon    : ${dev}
EOF
}

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# --- main ------------------------------------------------------------------

cmd="${1:-auto}"
case "$cmd" in
  -h|--help)        usage ;;
  --status)         status ;;
  --load)           load_modules ;;
  --sign-only)      detect_distro; sign_modules ;;
  --sign-and-load)
    detect_distro
    if secure_boot_on; then
      if [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]]; then sign_modules
      else warn "Secure Boot on but no key at ${MOK_DIR}; load will fail until a key is enrolled."; fi
    else
      log "Secure Boot off — no signing needed."
    fi
    load_modules ;;
  --enroll)         detect_distro; require_modules; ensure_key; enroll_key ;;
  --install-hook)   install_hook ;;
  --uninstall-hook) uninstall_hook ;;
  auto)
    detect_distro
    command -v vmware >/dev/null 2>&1 || warn "vmware not in PATH — continuing anyway."
    require_modules
    if ! secure_boot_on; then
      log "Secure Boot is OFF — no signing needed."
      load_modules; exit 0
    fi
    log "Secure Boot is ON — modules must be signed."
    ensure_key
    sign_modules
    if key_enrolled; then
      log "Key already enrolled."
      load_modules
    else
      enroll_key
    fi ;;
  *) die "Unknown option: $cmd  (try --help)" ;;
esac
