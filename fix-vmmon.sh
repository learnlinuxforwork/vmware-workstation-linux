#!/usr/bin/env bash
#
# fix-vmmon.sh — Load VMware Workstation's vmmon/vmnet modules on a
# Secure Boot system by signing them with a Machine Owner Key (MOK).
#
# Supported distributions:
#   * Ubuntu — LTS releases only (e.g. 26.04, 24.04, 22.04, 20.04)
#   * Rocky Linux 8 / 9 / 10
# Other distros may work but are untested; the script warns and continues.
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

DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_PRETTY=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- distro handling --------------------------------------------------------

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
    "")
      warn "Could not read /etc/os-release — distribution unknown. Continuing anyway."
      ;;
    *)
      warn "Detected ${DISTRO_PRETTY}. Supported: Ubuntu LTS and Rocky Linux 8/9/10."
      warn "This distro is untested; continuing anyway."
      ;;
  esac
}

headers_hint() {
  case "$DISTRO_ID" in
    ubuntu) echo "sudo apt install linux-headers-${KVER} openssl mokutil" ;;
    rocky)  echo "sudo dnf install kernel-devel-${KVER} openssl mokutil" ;;
    *)      echo "install the kernel headers/devel package for ${KVER}, plus openssl and mokutil" ;;
  esac
}

# --- helpers --------------------------------------------------------------

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

module_path() {
  # VMware installs uncompressed .ko; handle compressed variants just in case.
  for f in "${MOD_DIR}/$1.ko" "${MOD_DIR}/$1.ko.zst" "${MOD_DIR}/$1.ko.xz"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

module_is_signed() {
  modinfo "$1" 2>/dev/null | grep -q '^sig_id:'
}

sign_module() {
  local ko; ko="$(module_path "$1")" || die "${MOD_DIR}/$1.ko not found. Build it first:
  sudo vmware-modconfig --console --install-all"

  case "$ko" in
    *.zst)
      log "Decompressing $(basename "$ko")"
      sudo unzstd -qf "$ko"; ko="${ko%.zst}" ;;
    *.xz)
      log "Decompressing $(basename "$ko")"
      sudo xz -dqf "$ko"; ko="${ko%.xz}" ;;
  esac

  log "Signing $(basename "$ko")"
  sudo "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$ko"
  module_is_signed "$ko" && log "  $(basename "$ko") is now signed" \
                         || warn "  $(basename "$ko") signature not detected"

  # Recompress if the distro ships modules compressed (module dir has *.ko.zst).
  if compgen -G "${MOD_DIR}/*.ko.zst" >/dev/null 2>&1 && [[ "$ko" != *.zst ]]; then
    log "Recompressing $(basename "$ko").zst"
    sudo zstd -qf --rm "$ko"
  elif compgen -G "${MOD_DIR}/*.ko.xz" >/dev/null 2>&1 && [[ "$ko" != *.xz ]]; then
    log "Recompressing $(basename "$ko").xz"
    sudo xz -qf "$ko"
  fi
}

load_modules() {
  log "Loading modules: ${MODULES[*]}"
  sudo depmod -a "$KVER"
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

detect_distro

command -v vmware >/dev/null 2>&1 || warn "vmware not found in PATH — continuing anyway."

for m in "${MODULES[@]}"; do
  module_path "$m" >/dev/null || die "${MOD_DIR}/${m}.ko not found. Build it first:
  sudo vmware-modconfig --console --install-all"
done

if ! secure_boot_on; then
  log "Secure Boot is OFF — no signing needed."
  load_modules
  exit 0
fi

log "Secure Boot is ON — modules must be signed."

SIGN_FILE="$(find_sign_file)" || die "sign-file not found. Install kernel headers:
  $(headers_hint)"
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
  sign_module "$m"
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
