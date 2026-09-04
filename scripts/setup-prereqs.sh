#!/usr/bin/env bash
# One-time host setup for hardware work.
#
# Run as your normal user, NOT as root: some steps install into your home
# directory and would land in root's if run under sudo. The script calls sudo
# itself for the few steps that need it, so it will prompt.
#
# Everything here is idempotent. Re-running it is safe and is the quickest way
# to check the host is still set up correctly.
#
#   ./scripts/setup-prereqs.sh            # show a plan, confirm, then do it
#   ./scripts/setup-prereqs.sh --check    # verify only, change nothing
#   ./scripts/setup-prereqs.sh --yes      # no confirmation prompt
#   ./scripts/setup-prereqs.sh --skip-tools   # skip pyocd/probe-rs (probe-rs
#                                             # compiles, which takes minutes,
#                                             # and Track A needs no probe)
#
# Deliberately NOT done here: anything destructive to a board. Replacing the
# Feather's UF2 bootloader and the flash/UICR backup that must precede it are a
# separate, deliberate act.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PROBE_VID_PID="2e8a:000c"
PROBE_FW_VERSION="debugprobe-v2.3.1"
PROBE_FW_URL="https://github.com/raspberrypi/debugprobe/releases/download/${PROBE_FW_VERSION}/debugprobe.uf2"
UDEV_RULES="udev/90-runtt.rules"
UDEV_DEST="/etc/udev/rules.d/90-runtt.rules"
APT_PACKAGES=(pkg-config libudev-dev python3-pip python3-venv)

CHECK_ONLY=0
ASSUME_YES=0
SKIP_TOOLS=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --skip-tools) SKIP_TOOLS=1 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
ok()    { echo "  ${G}ok${N}    $*"; }
todo()  { echo "  ${Y}todo${N}  $*"; }
bad()   { echo "  ${R}fail${N}  $*"; }
note()  { echo "        $*"; }
head2() { echo; echo "${B}$*${N}"; }

[[ $EUID -ne 0 ]] || {
  echo "Run this as your normal user, not with sudo." >&2
  echo "It calls sudo only for the steps that need it; running the whole thing" >&2
  echo "as root would install tooling into root's home instead of yours." >&2
  exit 1
}

# ============================================================================
# Work out what needs doing
# ============================================================================
NEED_APT=()
for p in "${APT_PACKAGES[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED_APT+=("$p")
done

NEED_UDEV=0
if [[ ! -f "$UDEV_DEST" ]] || ! cmp -s "$UDEV_RULES" "$UDEV_DEST"; then
  NEED_UDEV=1
fi

NEED_GROUPS=()
for g in plugdev dialout; do
  id -nG | tr ' ' '\n' | grep -qx "$g" || NEED_GROUPS+=("$g")
done

# The probe reports its firmware version in bcdDevice. v1.xx is the old
# generation with 3 USB interfaces; probe-rs refuses it outright.
PROBE_PRESENT=0
PROBE_FW=""
NEED_PROBE_FW=0
if lsusb -d "$PROBE_VID_PID" >/dev/null 2>&1; then
  PROBE_PRESENT=1
  PROBE_FW="$(lsusb -v -d "$PROBE_VID_PID" 2>/dev/null | awk '/bcdDevice/ {print $2; exit}')"
  case "$PROBE_FW" in
    2.*|3.*) ;;
    *) NEED_PROBE_FW=1 ;;
  esac
fi

NEED_TOOLS=()
if [[ $SKIP_TOOLS -eq 0 ]]; then
  command -v pyocd    >/dev/null || NEED_TOOLS+=(pyocd)
  command -v probe-rs >/dev/null || NEED_TOOLS+=(probe-rs)
fi

# ============================================================================
# Report
# ============================================================================
echo "${B}runtt runtime — host prerequisites${N}"

head2 "1. Build dependencies (needs sudo)"
if [[ ${#NEED_APT[@]} -eq 0 ]]; then
  ok "all present: ${APT_PACKAGES[*]}"
else
  todo "apt install ${NEED_APT[*]}"
  note "libudev-dev and pkg-config are needed for the USB hotplug monitor."
  note "Nothing currently built requires them; target resolution reads sysfs."
fi

head2 "2. Device access (needs sudo)"
if [[ $NEED_UDEV -eq 0 ]]; then
  ok "udev rules installed and current"
else
  todo "install $UDEV_RULES -> $UDEV_DEST"
  note "Without these, NEITHER half of the Debug Probe is usable as your user:"
  note "the UART bridge is root:dialout 0660 with no ACL, and the CMSIS-DAP"
  note "interface that probe-rs needs read-write is root:root 0664."
fi
if [[ ${#NEED_GROUPS[@]} -eq 0 ]]; then
  ok "in plugdev and dialout"
else
  todo "add you to: ${NEED_GROUPS[*]}"
  note "dialout matters for TARGET boards whose CDC devices do not yet"
  note "advertise our interface descriptors."
fi

head2 "3. Debug Probe firmware (physical step)"
if [[ $PROBE_PRESENT -eq 0 ]]; then
  todo "probe not connected — cannot check its firmware"
elif [[ $NEED_PROBE_FW -eq 0 ]]; then
  ok "firmware $PROBE_FW (v2.x or newer)"
else
  todo "firmware is $PROBE_FW; needs $PROBE_FW_VERSION"
  note "probe-rs refuses old debugprobe firmware with an outdated-firmware error."
fi

head2 "4. Probe tooling (no sudo)"
if [[ $SKIP_TOOLS -eq 1 ]]; then
  note "skipped (--skip-tools); only needed for SWD work, not for USB bring-up"
elif [[ ${#NEED_TOOLS[@]} -eq 0 ]]; then
  ok "pyocd and probe-rs present"
else
  todo "install: ${NEED_TOOLS[*]}"
  note "pyocd via pip --user; probe-rs via cargo install probe-rs-tools."
  note "OpenOCD is not needed: probe-rs and pyOCD both cover nRF52840 and RP2040."
fi

NOTHING_TO_DO=0
if [[ ${#NEED_APT[@]} -eq 0 && $NEED_UDEV -eq 0 && ${#NEED_GROUPS[@]} -eq 0 \
      && $NEED_PROBE_FW -eq 0 && ${#NEED_TOOLS[@]} -eq 0 ]]; then
  NOTHING_TO_DO=1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  [[ $NOTHING_TO_DO -eq 1 ]] && echo "${G}Nothing to do.${N}" || echo "${Y}Run without --check to apply.${N}"
  exit 0
fi

if [[ $NOTHING_TO_DO -eq 1 ]]; then
  echo
  echo "${G}Nothing to do — verifying anyway.${N}"
else
  if [[ $ASSUME_YES -eq 0 ]]; then
    echo
    read -r -p "Apply the steps marked 'todo'? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
  fi
fi

# ============================================================================
# Apply
# ============================================================================
if [[ ${#NEED_APT[@]} -gt 0 ]]; then
  head2 "Installing build dependencies"
  sudo apt-get update -qq
  sudo apt-get install -y "${NEED_APT[@]}"
fi

if [[ $NEED_UDEV -eq 1 ]]; then
  head2 "Installing udev rules"
  sudo install -m 0644 "$UDEV_RULES" "$UDEV_DEST"
  # plugdev is not guaranteed to exist on a fresh Ubuntu 24.04.
  getent group plugdev >/dev/null || sudo groupadd -r plugdev
  sudo udevadm control --reload
  sudo udevadm trigger
  echo "  installed $UDEV_DEST and reloaded udev"
fi

if [[ ${#NEED_GROUPS[@]} -gt 0 ]]; then
  head2 "Adding you to groups"
  for g in "${NEED_GROUPS[@]}"; do
    getent group "$g" >/dev/null || sudo groupadd -r "$g"
    sudo usermod -aG "$g" "$USER"
    echo "  added $USER to $g"
  done
  GROUPS_CHANGED=1
fi

if [[ ${#NEED_TOOLS[@]} -gt 0 ]]; then
  head2 "Installing probe tooling"
  for t in "${NEED_TOOLS[@]}"; do
    case "$t" in
      pyocd)
        # --break-system-packages is required on Ubuntu 24.04 (PEP 668) even for
        # a --user install; it does not touch system site-packages.
        python3 -m pip install --user --break-system-packages -q pyocd \
          && echo "  installed pyocd" \
          || echo "  ${Y}pyocd install failed${N} — is pip available? try: sudo apt install python3-pip"
        ;;
      probe-rs)
        if command -v cargo >/dev/null; then
          echo "  installing probe-rs-tools (this compiles; it takes a few minutes)"
          cargo install --locked probe-rs-tools \
            && echo "  installed probe-rs" \
            || echo "  ${Y}probe-rs install failed${N}"
        else
          echo "  ${Y}skipped probe-rs${N} — cargo not on PATH"
        fi
        ;;
    esac
  done
fi

if [[ $NEED_PROBE_FW -eq 1 ]]; then
  head2 "Debug Probe firmware"
  echo "  Your probe reports firmware $PROBE_FW; $PROBE_FW_VERSION is current."
  echo
  echo "  This needs a physical step I cannot do for you:"
  echo "    1. Unplug the Debug Probe."
  echo "    2. Hold its BOOTSEL button while plugging it back in."
  echo "       It appears as a USB volume named RPI-RP2."
  echo "    3. Copy the .uf2 onto that volume. It reboots itself."
  echo
  if [[ $ASSUME_YES -eq 1 ]]; then
    reply=y
  else
    read -r -p "  Download the firmware now, ready to copy? [y/N] " reply
  fi
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    DEST="$HOME/Downloads"
    mkdir -p "$DEST"
    if curl -sSL --fail -o "$DEST/debugprobe.uf2" "$PROBE_FW_URL"; then
      echo "  downloaded $DEST/debugprobe.uf2 ($(stat -c %s "$DEST/debugprobe.uf2") bytes)"
      echo
      echo "  ${B}Take debugprobe.uf2, not debugprobe_on_pico.uf2${N} — the latter turns"
      echo "  a bare Pico INTO a probe and is the wrong firmware for this device."
      echo
      echo "  Once RPI-RP2 is mounted, copy it:"
      echo "    cp $DEST/debugprobe.uf2 /media/\$USER/RPI-RP2/"
    else
      echo "  ${Y}download failed${N} — fetch it manually from:"
      echo "    https://github.com/raspberrypi/debugprobe/releases/tag/$PROBE_FW_VERSION"
    fi
  fi
fi

# ============================================================================
# Verify
# ============================================================================
head2 "Verification"

if [[ -f "$UDEV_DEST" ]] && cmp -s "$UDEV_RULES" "$UDEV_DEST"; then
  ok "udev rules in place"
else
  bad "udev rules not installed"
fi

if [[ -n "${GROUPS_CHANGED:-}" ]]; then
  todo "group membership changed — ${B}log out and back in${N} for it to take effect"
  note "or start a new login shell with: newgrp plugdev"
  note "Until then the device checks below will still fail."
fi

if [[ $PROBE_PRESENT -eq 1 ]]; then
  # The device number changes on replug, so derive the usbfs path rather than
  # hardcoding it.
  P="$(lsusb -d "$PROBE_VID_PID" | sed -E 's/Bus ([0-9]+) Device ([0-9]+).*/\/dev\/bus\/usb\/\1\/\2/')"
  if python3 -c "open('$P','rb+').close()" 2>/dev/null; then
    ok "CMSIS-DAP interface is readable and writable ($P)"
  else
    bad "cannot open $P read-write — flashing will not work"
  fi
  TTY="$(ls /dev/ttyACM* 2>/dev/null | head -1 || true)"
  if [[ -n "$TTY" ]]; then
    if python3 -c "open('$TTY','rb').close()" 2>/dev/null; then
      ok "serial device is readable ($TTY)"
    else
      bad "cannot open $TTY"
    fi
  fi
else
  note "probe not connected; skipping device checks"
fi

for t in pyocd probe-rs; do
  command -v "$t" >/dev/null && ok "$t $("$t" --version 2>&1 | head -1)" || todo "$t not on PATH"
done

echo
echo "Re-run with --check at any time to re-verify."
# Point at docs that actually ship. docs/PREREQUISITES.md is a local working
# note and is gitignored, so on a fresh clone this named a file that was not
# there.
echo "Remaining hardware steps, which are deliberately not automated:"
echo "  docs/PROVISIONING.md     - getting a board manageable in the first place,"
echo "                             including backing up the Feather BEFORE its"
echo "                             bootloader is replaced"
echo "  NOTES.md - which boards are supported and what each needs"
