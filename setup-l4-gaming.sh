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
#
# Safe to re-run. If no NVIDIA driver is present, it installs one and asks you to
# reboot and run the script again.
set -euo pipefail

GAMER_USER="${GAMER_USER:-gamer}"
RESOLUTION="${RESOLUTION:-1920x1080}"
REFRESH="${REFRESH:-60}"
ALLOW_FROM="${ALLOW_FROM:-}"

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
apt-get install -y software-properties-common pciutils curl jq ca-certificates
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
if ! command -v sunshine >/dev/null; then
  log "Installing Sunshine (latest release)"
  # Release assets are named like sunshine_<ver>-1+ubuntu24.04_amd64.deb
  SUFFIX="+ubuntu${VERSION_ID}_amd64.deb"
  URL=$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
        | jq -r --arg s "$SUFFIX" '[.assets[] | select(.name | endswith($s))][0].browser_download_url // empty')
  [[ -n $URL ]] || die "the latest Sunshine release has no *${SUFFIX} package. Use an Ubuntu 24.04 GPU image."
  ASSET=${URL##*/}
  DL_DIR=$(mktemp -d)
  curl -fsSL -o "$DL_DIR/$ASSET" "$URL"
  apt-get install -y "$DL_DIR/$ASSET"
  rm -rf "$DL_DIR"
fi

# ------------------------------------------------------------------ gamer account
log "Setting up user '${GAMER_USER}'"
id "$GAMER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$GAMER_USER"
usermod -aG video,render,input,audio "$GAMER_USER"
loginctl enable-linger "$GAMER_USER"   # user services start at boot, no login needed
GAMER_HOME=$(getent passwd "$GAMER_USER" | cut -d: -f6)
GAMER_UID=$(id -u "$GAMER_USER")

# Sunshine injects keyboard/mouse/gamepad input through uinput. The packaged udev
# rule relies on a logged-in seat, which a headless box never has, so grant the
# 'input' group instead.
echo uinput > /etc/modules-load.d/uinput.conf
modprobe uinput
cat > /etc/udev/rules.d/85-sunshine-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
udevadm control --reload-rules
chgrp input /dev/uinput && chmod 0660 /dev/uinput

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
mkdir -p "$UNIT_DIR/default.target.wants"
WAIT_X="ExecStartPre=/bin/sh -c 'until xset q >/dev/null 2>&1; do sleep 1; done'"
STEAM_BIN=$(command -v steam || echo /usr/games/steam)

cat > "$UNIT_DIR/desktop.service" <<EOF
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

cat > "$UNIT_DIR/sunshine-headless.service" <<EOF
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

cat > "$UNIT_DIR/steam.service" <<EOF
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
  ln -sf "../$u.service" "$UNIT_DIR/default.target.wants/$u.service"
done

# ------------------------------------------------------------- Sunshine settings
SUN_DIR="$GAMER_HOME/.config/sunshine"
mkdir -p "$SUN_DIR"
if [[ ! -f $SUN_DIR/sunshine.conf ]]; then
  cat > "$SUN_DIR/sunshine.conf" <<'EOF'
# Generated by setup-l4-gaming.sh
capture = x11
encoder = nvenc
# Web UI only from localhost/LAN: reach it through an SSH tunnel, never expose it.
origin_web_ui_allowed = lan
EOF
fi
chown -R "$GAMER_USER:" "$GAMER_HOME/.config"

PASS_FILE=/root/sunshine-webui-credentials.txt
if [[ ! -f $PASS_FILE ]]; then
  log "Setting Sunshine web UI credentials"
  PASS=$(openssl rand -hex 12)   # no pipe: `tr </dev/urandom | head` dies of SIGPIPE under pipefail
  runuser -u "$GAMER_USER" -- env HOME="$GAMER_HOME" sunshine --creds admin "$PASS" >/dev/null
  umask 077
  printf 'user: admin\npassword: %s\n' "$PASS" > "$PASS_FILE"
fi

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
