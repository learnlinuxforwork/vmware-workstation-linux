#!/usr/bin/env bash
#
# fix-vmmon.sh — Load VMware Workstation's vmmon/vmnet modules on a
# Secure Boot system by signing them with a Machine Owner Key (MOK).
#
# Safe to re-run. Run it again after every kernel update.
#
#   ./fix-vmmon.sh            # sign + enrol + load (may require a reboot once)
#   ./fix-vmmon.sh --load     # only try to load the modules
#
set -euo pipefail

MOK_DIR="${HOME}/.mok"
MOK_PRIV="${MOK_DIR}/MOK.priv"
MOK_DER="${MOK_DIR}/MOK.der"
KVER="$(uname -r)"
MOD_DIR="/lib/modules/${KVER}/misc"
MODULES=(vmmon vmnet)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

find_sign_file() {
  for p in \
    "/usr/src/linux-headers-${KVER}/scripts/sign-file" \
    "/lib/modules/${KVER}/build/scripts/sign-file"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

secure_boot_on() {
  command -v mokutil >/dev/null 2>&1 || return 1
  mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

module_is_signed() {
  modinfo "${MOD_DIR}/$1.ko" 2>/dev/null | grep -q '^sig_id:'
}

load_modules() {
  log "Loading modules: ${MODULES[*]}"
  sudo modprobe "${MODULES[@]}"
  if [[ -e /dev/vmmon ]]; then
    log "Success — /dev/vmmon is present:"
    ls -l /dev/vmmon /dev/vmnet* 2>/dev/null || true
    return 0
  fi
  die "modprobe returned but /dev/vmmon still missing — check: sudo dmesg | tail"
}

# --- entry point --------------------------------------------------------------

[[ "${1:-}" == "--load" ]] && { load_modules; exit 0; }

command -v vmware >/dev/null 2>&1 || warn "vmware not found in PATH — continuing anyway."

for m in "${MODULES[@]}"; do
  [[ -f "${MOD_DIR}/${m}.ko" ]] || die "${MOD_DIR}/${m}.ko not found. Build it first:
  sudo vmware-modconfig --console --install-all"
done

if ! secure_boot_on; then
  log "Secure Boot is OFF — no signing needed."
  load_modules
  exit 0
fi

log "Secure Boot is ON — modules must be signed."

SIGN_FILE="$(find_sign_file)" || die "sign-file not found. Install kernel headers:
  sudo apt install linux-headers-${KVER}"
log "Using sign-file: ${SIGN_FILE}"

# 1. Key ------------------------------------------------------------------------
if [[ -f "$MOK_PRIV" && -f "$MOK_DER" ]]; then
  log "Reusing existing MOK key in ${MOK_DIR}"
else
  log "Generating MOK key in ${MOK_DIR}"
  mkdir -p "$MOK_DIR"; chmod 700 "$MOK_DIR"
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout "$MOK_PRIV" -outform DER -out "$MOK_DER" \
    -subj "/CN=VMware Module Signing ($(hostname))/"
  chmod 600 "$MOK_PRIV"
fi

# 2. Sign ---------------------------------------------------------------------
for m in "${MODULES[@]}"; do
  log "Signing ${m}.ko"
  sudo "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "${MOD_DIR}/${m}.ko"
  module_is_signed "$m" && log "  ${m}.ko is now signed" || warn "  ${m}.ko signature not detected"
done

# 3. Enrolment --------------------------------------------------------------
if sudo mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi 'already enrolled'; then
  log "MOK already enrolled in firmware."
  load_modules
  exit 0
fi

log "Enrolling MOK. You will be asked to set a one-time password."
warn "Remember it — you must retype it in the blue 'MOK Manager' screen on reboot."
sudo mokutil --import "$MOK_DER"

cat <<EOF

------------------------------------------------------------------------
Next steps:
  1. Reboot:            sudo reboot
  2. On the blue MOK Manager screen:
        Enroll MOK  ->  Continue  ->  Yes  ->  (enter the password above)
  3. After it boots, run:
        $(realpath "$0") --load
------------------------------------------------------------------------
EOF
