#!/usr/bin/env bash
# setup-l4-gaming.sh
#
# Turns a Scaleway L4-1-24G GPU instance (Ubuntu) into a headless cloud gaming box:
#   NVIDIA Xorg on a virtual display  ->  Steam (Big Picture)  ->  Sunshine (NVENC)
# Stream it with Moonlight (Android TV, laptop, phone).
#
# Usage, as root on the GPU instance:
#   ALLOW_FROM=203.0.113.7/32 bash setup-l4-gaming.sh
#
# Options (environment variables):
#   GAMER_USER   local account that runs Steam and Sunshine  (default: gamer)
#   RESOLUTION   virtual display size                        (default: 1920x1080)
#   REFRESH      virtual display refresh rate, Hz            (default: 60)
#   ALLOW_FROM   IP/CIDR allowed to stream, applied to ufw    (default: any)
#   SUNSHINE_VERSION  exact Sunshine release to install, pinned (default: 2026.1119.204022)
#
# Safe to re-run. If no NVIDIA driver is present, it installs one and asks you to
# reboot and run the script again.
set -euo pipefail

GAMER_USER="${GAMER_USER:-gamer}"
RESOLUTION="${RESOLUTION:-1920x1080}"
REFRESH="${REFRESH:-60}"
ALLOW_FROM="${ALLOW_FROM:-}"
# Sunshine is pinned to an exact, tested version; there is deliberately no "latest".
# Bump it by hand after testing a new release. The current pin is a pre-release: the
# stable v2026.914 lacks libvirtualhid's fix for virtual Switch Pro pads going idle,
# which makes Steam drop and re-add the controller in a loop
# (LizardByte/libvirtualhid#176, fixed by #180).
SUNSHINE_VERSION="${SUNSHINE_VERSION:-2026.1119.204022}"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this as root"
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu ]] || die "Ubuntu only (found: $ID)"
[[ $RESOLUTION =~ ^[0-9]+x[0-9]+$ ]] || die "RESOLUTION must look like 1920x1080"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- base packages
log "Enabling multiverse and 32-bit packages"
apt-get update
apt-get install -y software-properties-common pciutils curl jq ca-certificates cloud-guest-utils
lspci | grep -qi nvidia || die "no NVIDIA GPU found - is this a GPU instance?"
add-apt-repository -y multiverse
dpkg --add-architecture i386
apt-get update

# ---------------------------------------------------------------- NVIDIA driver
log "Checking the NVIDIA driver"
if ! nvidia-smi >/dev/null 2>&1; then
  apt-get install -y ubuntu-drivers-common
  ubuntu-drivers install
  log "NVIDIA driver installed. Reboot, then run this script again."
  exit 0
fi

DRV_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
DRV_MAJOR=${DRV_VER%%.*}
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
if installed "libnvidia-compute-${DRV_MAJOR}-server"; then
  SFX="${DRV_MAJOR}-server"
elif installed "libnvidia-compute-${DRV_MAJOR}"; then
  SFX="${DRV_MAJOR}"
else
  die "driver ${DRV_VER} was not installed from apt packages (.run installer?).
Install its Xorg, GL (incl. 32-bit), encode and FBC components yourself, then re-run."
fi

log "Installing graphics libraries for driver ${DRV_VER} (packages: *-${SFX})"
apt-get install -y \
  "xserver-xorg-video-nvidia-${SFX}" \
  "libnvidia-gl-${SFX}" "libnvidia-gl-${SFX}:i386" \
  "libnvidia-encode-${SFX}" "libnvidia-decode-${SFX}" "libnvidia-fbc1-${SFX}"

# ------------------------------------------------- desktop, audio, Steam packages
log "Installing Xorg, Openbox, PipeWire and Steam"
apt-get install -y \
  xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils xterm openbox dbus-user-session \
  pipewire pipewire-pulse wireplumber pulseaudio-utils \
  libvulkan1 libvulkan1:i386 \
  steam-installer steam-libs-amd64 steam-libs-i386

if systemctl is-active --quiet display-manager 2>/dev/null; then
  warn "a display manager is running; it may grab the GPU. Consider: systemctl disable --now display-manager"
fi

# ---------------------------------------------------------------------- Sunshine
[[ $SUNSHINE_VERSION =~ ^[0-9]+(\.[0-9]+)+$ ]] \
  || die "SUNSHINE_VERSION must be an exact release number like 2026.1119.204022, got '${SUNSHINE_VERSION}'"
# dpkg already records the installed version (e.g. 2026.1119.204022-1+ubuntu24.04);
# GitHub is only contacted when it differs from the pin, so re-runs work offline.
HAVE_VER=""
installed sunshine && HAVE_VER=$(dpkg-query -W -f='${Version}' sunshine)
if [[ ${HAVE_VER%%-*} == "$SUNSHINE_VERSION" ]]; then
  log "Sunshine ${SUNSHINE_VERSION} already installed"
else
  log "Installing Sunshine ${SUNSHINE_VERSION} (currently: ${HAVE_VER:-none})"
  RELEASE_API="https://api.github.com/repos/LizardByte/Sunshine/releases/tags/v${SUNSHINE_VERSION}"
  RELEASE_JSON=$(curl -fsSL "$RELEASE_API") \
    || die "cannot fetch Sunshine release v${SUNSHINE_VERSION} from GitHub (wrong version, release deleted, rate limit or no network)"
  # Assets are named like sunshine_<ver>-1+ubuntu24.04_amd64.deb. Use the asset
  # *name*: browser_download_url percent-encodes the '+' (%2B).
  SUFFIX="+ubuntu${VERSION_ID}_amd64.deb"
  ASSET="" URL=""
  read -r ASSET URL < <(jq -r --arg s "$SUFFIX" \
    '([.assets[] | select(.name | endswith($s))][0] // empty) | "\(.name) \(.browser_download_url)"' \
    <<<"$RELEASE_JSON") || true
  [[ -n $ASSET ]] || die "Sunshine release v${SUNSHINE_VERSION} has no *${SUFFIX} package. Use an Ubuntu 24.04 GPU image."
  DL_DIR=$(mktemp -d)
  curl -fsSL -o "$DL_DIR/$ASSET" "$URL"
  # --allow-downgrades: the pin wins, even over a newer Sunshine installed by hand.
  apt-get install -y --allow-downgrades "$DL_DIR/$ASSET"
  rm -rf "$DL_DIR"
fi

# ------------------------------------------------------------------ gamer account
log "Setting up user '${GAMER_USER}'"
id "$GAMER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$GAMER_USER"
usermod -aG video,render,input,audio "$GAMER_USER"
loginctl enable-linger "$GAMER_USER"   # user services start at boot, no login needed
GAMER_HOME=$(getent passwd "$GAMER_USER" | cut -d: -f6)
GAMER_UID=$(id -u "$GAMER_USER")
# Files below are created by the gamer itself (see as_gamer), so it must own its home.
[[ -d $GAMER_HOME && ! -L $GAMER_HOME && $(stat -c %U "$GAMER_HOME") == "$GAMER_USER" ]] \
  || die "home ${GAMER_HOME} of '${GAMER_USER}' must be a directory owned by ${GAMER_USER}"
if [[ -e $GAMER_HOME/.config && $(stat -c %U "$GAMER_HOME/.config") != "$GAMER_USER" ]]; then
  die "${GAMER_HOME}/.config is not owned by ${GAMER_USER}. Check it, then: chown -R ${GAMER_USER}: ${GAMER_HOME}/.config"
fi

# Everything under the gamer's home is written AS the gamer. Steam and games run as
# that user, so it is untrusted: writing there as root would follow any symlink it
# planted (e.g. desktop.service -> /etc/sudoers.d/x) and overwrite system files.
as_gamer()       { runuser -u "$GAMER_USER" -- env HOME="$GAMER_HOME" "$@"; }
write_as_gamer() { as_gamer tee "$1" >/dev/null; }

# Sunshine injects keyboard/mouse through uinput, and creates Switch Pro / DualSense
# virtual gamepads through uhid (otherwise every pad falls back to Xbox and buttons
# from a Switch Pro client get scrambled). Cloud kernels ship uhid and hid-nintendo
# in linux-modules-extra. The packaged udev rules rely on a logged-in seat, which a
# headless box never has, so grant the 'input' group instead. (Sunshine's own
# 60-sunshine.rules already gives 'input' the virtual pads' /dev/hidraw*, so Steam
# can drive them natively.)
# Scaleway's image installs the kernel through the linux-virtual meta-package, which
# leaves linux-modules-extra out. Install the extras for the running kernel now, and
# the linux-image-generic meta-package (same -generic kernel, plus its extras) so
# every future kernel update brings them too. The NVIDIA driver is DKMS-built, so it
# follows kernel updates on its own.
KVER=$(uname -r)
if [[ $KVER == *-generic ]]; then
  apt-get install -y --no-install-recommends linux-image-generic "linux-modules-extra-${KVER}" \
    || warn "could not install linux-modules-extra; virtual Switch/PlayStation pads will fall back to Xbox"
elif ! modprobe -n uhid 2>/dev/null; then
  apt-get install -y "linux-modules-extra-${KVER}" \
    || warn "no linux-modules-extra for kernel ${KVER}; virtual Switch/PlayStation pads will fall back to Xbox"
fi
modprobe uinput
modprobe uhid || true
printf 'uinput\nuhid\n' > /etc/modules-load.d/uinput.conf
cat > /etc/udev/rules.d/85-sunshine-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uhid"
EOF
rm -f /etc/udev/rules.d/99-sunshine-no-hidraw.rules   # workaround from an older version of this script
udevadm control --reload-rules
for dev in /dev/uinput /dev/uhid; do
  if [[ -e $dev ]]; then chgrp input "$dev"; chmod 0660 "$dev"; fi
done
[[ -e /dev/uhid ]] || warn "/dev/uhid is missing: virtual Switch/PlayStation pads will fall back to Xbox"

# ------------------------------------------------------- Xorg on a virtual display
log "Configuring a ${RESOLUTION}@${REFRESH} virtual display"
W=${RESOLUTION%x*}; H=${RESOLUTION#*x}
MODELINE=$(cvt "$W" "$H" "$REFRESH" | sed -n 's/^Modeline //p')
MODENAME=$(awk '{print $1}' <<<"$MODELINE" | tr -d '"')
PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | head -1)   # 00000000:01:00.0
IFS=':.' read -r P_DOM P_BUS P_DEV P_FN <<<"$PCI"
BUSID=$(printf 'PCI:%d@%d:%d:%d' "0x$P_BUS" "0x$P_DOM" "0x$P_DEV" "0x$P_FN")

cat > /etc/X11/xorg-headless.conf <<EOF
# Generated by setup-l4-gaming.sh: headless NVIDIA screen for game streaming
Section "ServerLayout"
    Identifier "Layout0"
    Screen     0 "Screen0"
EndSection

Section "ServerFlags"
    Option "AutoAddGPU"  "false"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Monitor"
    Identifier  "Monitor0"
    HorizSync   28.0-300.0
    VertRefresh 48.0-240.0
    Modeline    ${MODELINE}
    Option      "PreferredMode" "${MODENAME}"
EndSection

Section "Device"
    Identifier "Device0"
    Driver     "nvidia"
    BusID      "${BUSID}"
    Option     "AllowEmptyInitialConfiguration" "True"
    Option     "ConnectedMonitor" "DFP-0"
    Option     "ModeValidation" "NoMaxPClkCheck,NoEdidMaxPClkCheck,NoHorizSyncCheck,NoVertRefreshCheck,NoVirtualSizeCheck,AllowNonEdidModes,NoDFPNativeResolutionCheck"
EndSection

Section "Screen"
    Identifier   "Screen0"
    Device       "Device0"
    Monitor      "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Virtual ${W} ${H}
        Modes   "${MODENAME}"
    EndSubSection
EndSection
EOF

cat > /etc/systemd/system/xorg-headless.service <<EOF
[Unit]
Description=Headless Xorg on the NVIDIA GPU (game streaming)
After=systemd-user-sessions.service

[Service]
ExecStart=/usr/lib/xorg/Xorg :0 -config /etc/X11/xorg-headless.conf -nolisten tcp -noreset -novtswitch vt7
ExecStartPost=/bin/sh -c 'for i in \$(seq 30); do DISPLAY=:0 xhost +SI:localuser:${GAMER_USER} >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------ user-level services
log "Creating Openbox, Steam and Sunshine services for ${GAMER_USER}"
UNIT_DIR="$GAMER_HOME/.config/systemd/user"
as_gamer mkdir -p "$UNIT_DIR/default.target.wants"
WAIT_X="ExecStartPre=/bin/sh -c 'until xset q >/dev/null 2>&1; do sleep 1; done'"
STEAM_BIN=$(command -v steam || echo /usr/games/steam)

write_as_gamer "$UNIT_DIR/desktop.service" <<EOF
[Unit]
Description=Openbox window manager on :0

[Service]
Environment=DISPLAY=:0
${WAIT_X}
ExecStartPre=-/usr/bin/xset s off -dpms
ExecStart=/usr/bin/openbox
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

write_as_gamer "$UNIT_DIR/sunshine-headless.service" <<EOF
[Unit]
Description=Sunshine game stream host
Wants=desktop.service pipewire-pulse.service
After=desktop.service pipewire-pulse.service

[Service]
Environment=DISPLAY=:0
${WAIT_X}
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Ubuntu's steam-installer wrapper asks "Install Steam?" in a zenity dialog on first
# run, which would block a headless box. This shim, on the Steam service's PATH only,
# answers yes to that one question and passes every other dialog to the real zenity.
SHIM_DIR=/usr/local/lib/steamway
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/zenity" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "--title=Steam installer" ] && exit 0; done
exec /usr/bin/zenity "$@"
EOF
chmod 0755 "$SHIM_DIR/zenity"

write_as_gamer "$UNIT_DIR/steam.service" <<EOF
[Unit]
Description=Steam (Big Picture)
Wants=desktop.service pipewire-pulse.service
After=desktop.service pipewire-pulse.service

[Service]
Environment=DISPLAY=:0
Environment=PATH=${SHIM_DIR}:/usr/local/bin:/usr/bin:/bin:/usr/games
${WAIT_X}
# -cef-disable-gpu-compositing: with GPU compositing in Steam's embedded browser,
# Big Picture stays black on headless NVIDIA Xorg (GLXBadPixmap). This only affects
# Steam's own menus; games still render on the GPU.
ExecStart=${STEAM_BIN} -gamepadui -cef-disable-gpu-compositing
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

for u in desktop sunshine-headless steam; do
  as_gamer ln -sfn "../$u.service" "$UNIT_DIR/default.target.wants/$u.service"
done

# Openbox: open Steam games (Proton windows have class steam_app_<id>) full-screen
# without a title bar. Otherwise a windowed game gets a 16 px frame, and the bottom
# of its image is pushed off the streamed screen. keepBorder=no: undecorated windows
# would otherwise keep a 1 px border (a white line on the top and left edges).
as_gamer mkdir -p "$GAMER_HOME/.config/openbox"
sed -e 's|<keepBorder>yes</keepBorder>|<keepBorder>no</keepBorder>|' \
    -e 's|</applications>|  <application class="steam_app_*">\n    <decor>no</decor>\n    <fullscreen>yes</fullscreen>\n  </application>\n</applications>|' \
  /etc/xdg/openbox/rc.xml | write_as_gamer "$GAMER_HOME/.config/openbox/rc.xml"

# ------------------------------------------------------------- Sunshine settings
SUN_DIR="$GAMER_HOME/.config/sunshine"
as_gamer mkdir -p "$SUN_DIR"
if [[ ! -f $SUN_DIR/sunshine.conf ]]; then
  write_as_gamer "$SUN_DIR/sunshine.conf" <<'EOF'
# Generated by setup-l4-gaming.sh
capture = x11
encoder = nvenc
# Web UI only from localhost/LAN: reach it through an SSH tunnel, never expose it.
origin_web_ui_allowed = lan
EOF
fi

PASS_FILE=/root/sunshine-webui-credentials.txt
if [[ ! -f $PASS_FILE ]]; then
  log "Setting Sunshine web UI credentials"
  PASS=$(openssl rand -hex 12)   # no pipe: `tr </dev/urandom | head` dies of SIGPIPE under pipefail
  runuser -u "$GAMER_USER" -- env HOME="$GAMER_HOME" sunshine --creds admin "$PASS" >/dev/null
  umask 077
  printf 'user: admin\npassword: %s\n' "$PASS" > "$PASS_FILE"
fi

# Pairing helper: sends the PIN Moonlight shows to Sunshine's API, so pairing is one
# command (`ssh root@<ip> sunshine-pair 1234 tv`) instead of a tunnel + browser.
cat > /usr/local/sbin/sunshine-pair <<'EOF'
#!/usr/bin/env bash
# Usage: sunshine-pair <PIN> [device name]   (default name: the one Moonlight sends)
# If several devices are waiting, choose with PAIRING_ID=<id> (the script lists them).
set -euo pipefail
CREDS=/root/sunshine-webui-credentials.txt
PORT=${SUNSHINE_WEB_PORT:-47990}
[[ ${1:-} =~ ^[0-9]{4}$ ]] || { echo "Usage: sunshine-pair <4-digit PIN> [device name]" >&2; exit 2; }
PIN=$1
USER_=$(awk '/^user:/{print $2}' "$CREDS")
PASS=$(awk '/^password:/{print $2}' "$CREDS")
# Credentials go through stdin (curl -K -), not argv, so they don't show up in ps.
api() {
  printf 'user = "%s:%s"\n' "$USER_" "$PASS" | curl -sS -k --max-time 10 -K - \
    -H 'Content-Type: application/json' -H "Origin: https://localhost:${PORT}" \
    "$@" "https://localhost:${PORT}/api/pin" \
    || { echo "Could not reach Sunshine on port ${PORT}. Is it running?" >&2; exit 1; }
}
# The PIN answers one pending pairing request (what Moonlight opened when it showed
# the PIN). List them: {"pairings":[{"id","name","address"}]}.
PENDING=$(api)
# Name and address come from the remote client: strip control characters so they
# can't inject terminal escape sequences when printed.
PENDING=$(jq -c '.pairings |= map(map_values(if type == "string" then gsub("[[:cntrl:]]"; "?") else . end))' <<<"$PENDING")
COUNT=$(jq '.pairings | length' <<<"$PENDING")
if (( COUNT == 0 )); then
  echo "No pending pairing request. Select the PC in Moonlight so it shows a PIN, then retry." >&2
  exit 1
elif [[ -n ${PAIRING_ID:-} ]]; then
  REQ=$(jq -c --arg id "$PAIRING_ID" '.pairings[] | select(.id == $id)' <<<"$PENDING")
  [[ -n $REQ ]] || { echo "No pending request with id ${PAIRING_ID}." >&2; exit 1; }
elif (( COUNT == 1 )); then
  REQ=$(jq -c '.pairings[0]' <<<"$PENDING")
else
  echo "Several devices are waiting to pair. Pick one with PAIRING_ID=<id> sunshine-pair ${PIN}:" >&2
  jq -r '.pairings[] | "  \(.id)  \(.name // "?")  \(.address // "?")"' <<<"$PENDING" >&2
  exit 1
fi
ID=$(jq -r '.id' <<<"$REQ")
NAME=${2:-$(jq -r '.name // empty' <<<"$REQ")}
NAME=${NAME:-moonlight-$(date +%Y%m%d-%H%M%S)}
echo "Pairing $(jq -r '"\(.name // "unknown device") (\(.address // "unknown address"))"' <<<"$REQ") as '${NAME}'..."
BODY=$(jq -cn --arg id "$ID" --arg pin "$PIN" --arg name "$NAME" '{pairing_id: $id, pin: $pin, name: $name}')
RESP=$(api -d "$BODY")
if jq -e '.status == true or .status == "true"' >/dev/null 2>&1 <<<"$RESP"; then
  echo "Paired '${NAME}'."
else
  echo "Pairing failed: $(tr -d '\000-\010\013-\037\177' <<<"${RESP:-empty response}")" >&2
  echo "Check that Moonlight is still showing this PIN, then retry." >&2
  exit 1
fi
EOF
chmod 0700 /usr/local/sbin/sunshine-pair

# Root resize helper: after enlarging the system volume in the Scaleway console, run
# `grow-root` to make the space usable without a reboot. (cloud-init also grows the
# root partition at boot, so a reboot works too.)
cat > /usr/local/sbin/grow-root <<'EOF'
#!/usr/bin/env bash
# Usage: grow-root [-n]   (-n: dry run, only show what would change)
# Grows the partition holding / to the end of its disk, then the filesystem.
set -euo pipefail
DRY=0
case ${1:-} in -n|--dry-run) DRY=1 ;; "") ;; *) echo "Usage: grow-root [-n]" >&2; exit 2 ;; esac
die() { echo "grow-root: $*" >&2; exit 1; }
(( EUID == 0 )) || die "run as root"

SRC=$(findmnt -no SOURCE /)
FSTYPE=$(findmnt -no FSTYPE /)
PART=$(basename "$(readlink -f "$SRC")")
[[ -f /sys/class/block/$PART/partition ]] || die "/ is on ${SRC}, not a plain disk partition (LVM?); grow it by hand"
DISK=$(lsblk -no PKNAME "/dev/$PART")
PARTNUM=$(cat "/sys/class/block/$PART/partition")
size() { lsblk -bdno SIZE "/dev/$1" | numfmt --to=iec; }

# The kernel only sees the new size of the volume after a rescan.
BEFORE=$(size "$DISK")
if [[ -w /sys/class/block/$DISK/device/rescan ]]; then
  echo 1 > "/sys/class/block/$DISK/device/rescan"
  udevadm settle
fi
echo "Disk /dev/${DISK}: ${BEFORE} -> $(size "$DISK")"
echo "Partition /dev/${PART} (${FSTYPE} on /): $(size "$PART")"

# growpart exits 1 with "NOCHANGE" when the partition already fills the disk.
if (( DRY )); then
  growpart --dry-run "/dev/$DISK" "$PARTNUM" || true
  exit 0
fi
if OUT=$(growpart "/dev/$DISK" "$PARTNUM" 2>&1); then
  echo "$OUT"
elif [[ $OUT == NOCHANGE* ]]; then
  echo "Partition already fills the disk."
else
  die "growpart failed: $OUT"
fi

case $FSTYPE in
  ext2|ext3|ext4) resize2fs "/dev/$PART" ;;
  xfs)            xfs_growfs / ;;
  *)              die "don't know how to grow a ${FSTYPE} filesystem" ;;
esac
df -h /
EOF
chmod 0700 /usr/local/sbin/grow-root

# ---------------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  log "Opening Moonlight ports in ufw (from ${ALLOW_FROM:-any})"
  SRC=${ALLOW_FROM:-any}
  for p in 47984 47989 48010; do ufw allow proto tcp from "$SRC" to any port "$p"; done
  for p in 47998:48000 48002 48010; do ufw allow proto udp from "$SRC" to any port "$p"; done
fi

# ---------------------------------------------------------------------- start it
log "Starting services"
systemctl daemon-reload
systemctl enable xorg-headless.service
systemctl restart xorg-headless.service
for _ in $(seq 20); do DISPLAY=:0 xset q >/dev/null 2>&1 && break; sleep 1; done
DISPLAY=:0 xset q >/dev/null 2>&1 || die "Xorg did not start. Check: journalctl -u xorg-headless; /var/log/Xorg.0.log"
systemctl restart "user@${GAMER_UID}.service"

PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
cat <<EOF

=====================================================================
 Done. Stream host is running on ${PUBLIC_IP} (${RESOLUTION}@${REFRESH}).

 1. Scaleway security group: allow inbound from your home IP only
      TCP 47984, 47989, 48010   UDP 47998-48000, 48002, 48010
    Do NOT open 47990 (web UI).

 2. Pair Moonlight:
      - In Moonlight (TV or laptop): add PC manually -> ${PUBLIC_IP}
      - Then, from your laptop:  ssh root@${PUBLIC_IP} sunshine-pair <PIN> <device-name>
    Or, through the web UI:
      - On your laptop:  ssh -L 47990:localhost:47990 root@${PUBLIC_IP}
      - Open https://localhost:47990 (accept the self-signed cert)
        login: see ${PASS_FILE}
      - In Moonlight (TV or laptop): add PC manually -> ${PUBLIC_IP}
      - Enter the PIN Moonlight shows into the web UI "PIN" tab

 3. In Moonlight open "Desktop" once and log in to Steam (Steam Guard).
    After that, launch "Steam Big Picture" directly.

 Logs:  journalctl -u xorg-headless
        journalctl _SYSTEMD_USER_UNIT=sunshine-headless.service
        journalctl _SYSTEMD_USER_UNIT=steam.service
=====================================================================
EOF
